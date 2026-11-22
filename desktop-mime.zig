//! Content types from the shared-mime-info database, in Zig, with the
//! semantics GIO's xdgmime gives g_content_type_guess, g_content_type_is_a and
//! g_content_type_from_mime_type: weighted file name globs, magic sniffing,
//! aliases and the subclass hierarchy.
const std = @import("std");
const linux = std.os.linux;
const paths = @import("desktop-paths.zig");
const util = @import("desktop-util.zig");

pub const unknown = "application/octet-stream";
pub const empty = "application/x-zerosize";

pub const Database = struct {
    arena: std.heap.ArenaAllocator,
    literals: std.ArrayList(Glob) = .empty,
    /// "*.ext" patterns, matched as suffixes.
    suffixes: std.ArrayList(Glob) = .empty,
    /// Other patterns, matched with fnmatch rules.
    patterns: std.ArrayList(Glob) = .empty,
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    parents: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    /// Highest priority first; equal priorities keep file order.
    magic: std.ArrayList(Match) = .empty,
    /// How many leading bytes sniffing can examine.
    sniff_len: usize = 0,

    const Glob = struct { weight: u32, mime: []const u8, pattern: []const u8, case_sensitive: bool };
    const Match = struct { priority: u32, mime: []const u8, rules: []const Rule };
    const Rule = struct { indent: u32, start: usize, range: usize, value: []const u8, mask: ?[]const u8 };

    /// Reads mime/ under $XDG_DATA_HOME and each of $XDG_DATA_DIRS, highest priority first.
    pub fn load(gpa: std.mem.Allocator) !*Database {
        const self = try gpa.create(Database);
        self.* = .{ .arena = .init(gpa) };
        errdefer self.deinit();
        const a = self.arena.allocator();
        var directories: std.ArrayList([]const u8) = .empty;
        try directories.append(a, try std.fmt.allocPrint(a, "{s}/mime", .{paths.dataHome()}));
        const system = util.env("XDG_DATA_DIRS") orelse "";
        var dirs = std.mem.splitScalar(u8, if (system.len > 0) system else "/usr/local/share/:/usr/share/", ':');
        while (dirs.next()) |dir| if (dir.len > 0) try directories.append(a, try std.fmt.allocPrint(a, "{s}/mime", .{std.mem.trimEnd(u8, dir, "/")}));
        for (directories.items) |directory| {
            if (read(a, directory, "globs2")) |data| try self.addGlobs(a, data);
            if (read(a, directory, "aliases")) |data| try self.addAliases(a, data);
            if (read(a, directory, "subclasses")) |data| try self.addSubclasses(a, data);
            if (read(a, directory, "magic")) |data| self.addMagic(a, data) catch {};
        }
        return self;
    }

    pub fn deinit(self: *Database) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn read(a: std.mem.Allocator, directory: []const u8, name: []const u8) ?[]const u8 {
        const path = std.fmt.allocPrint(a, "{s}/{s}", .{ directory, name }) catch return null;
        return paths.readFile(a, path, 64 << 20) catch null;
    }

    fn addGlobs(self: *Database, a: std.mem.Allocator, data: []const u8) !void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, ':');
            const weight = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
            const mime = fields.next() orelse continue;
            const pattern = fields.next() orelse continue;
            const flags = fields.next() orelse "";
            // A higher-priority directory may clear the globs below it.
            if (std.mem.eql(u8, pattern, "__NOGLOBS__")) {
                inline for (.{ &self.literals, &self.suffixes, &self.patterns }) |list| {
                    var i: usize = 0;
                    while (i < list.items.len) if (std.mem.eql(u8, list.items[i].mime, mime)) {
                        _ = list.orderedRemove(i);
                    } else {
                        i += 1;
                    };
                }
                continue;
            }
            const glob: Glob = .{ .weight = weight, .mime = mime, .pattern = pattern, .case_sensitive = std.mem.indexOf(u8, flags, "cs") != null };
            const wild = std.mem.indexOfAny(u8, pattern, "*?[") != null;
            const list = if (!wild)
                &self.literals
            else if (pattern.len > 1 and pattern[0] == '*' and std.mem.indexOfAny(u8, pattern[1..], "*?[") == null)
                &self.suffixes
            else
                &self.patterns;
            // A repeated pattern for the same type keeps its first weight and flags.
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing.pattern, pattern) and std.mem.eql(u8, existing.mime, mime)) break;
            } else try list.append(a, glob);
        }
    }

    fn addAliases(self: *Database, a: std.mem.Allocator, data: []const u8) !void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const result = try self.aliases.getOrPut(a, line[0..space]);
            if (!result.found_existing) result.value_ptr.* = line[space + 1 ..];
        }
    }

    fn addSubclasses(self: *Database, a: std.mem.Allocator, data: []const u8) !void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const result = try self.parents.getOrPut(a, line[0..space]);
            if (!result.found_existing) result.value_ptr.* = .empty;
            try result.value_ptr.append(a, line[space + 1 ..]);
        }
    }

    /// The binary magic format: [priority:type] sections of
    /// [indent]>offset=<u16 length>value[&mask][~word][+range] rules.
    fn addMagic(self: *Database, a: std.mem.Allocator, data: []const u8) !void {
        const header = "MIME-Magic\x00\n";
        if (!std.mem.startsWith(u8, data, header)) return error.InvalidMagic;
        var i: usize = header.len;
        while (i < data.len) {
            if (data[i] != '[') return error.InvalidMagic;
            const close = std.mem.indexOfScalarPos(u8, data, i, ']') orelse return error.InvalidMagic;
            const colon = std.mem.indexOfScalarPos(u8, data, i, ':') orelse return error.InvalidMagic;
            const priority = try std.fmt.parseInt(u32, data[i + 1 .. colon], 10);
            const mime = data[colon + 1 .. close];
            i = close + 2;
            var rules: std.ArrayList(Rule) = .empty;
            while (i < data.len and data[i] != '[') {
                var rule: Rule = .{ .indent = 0, .start = 0, .range = 1, .value = "", .mask = null };
                if (data[i] != '>') {
                    const gt = std.mem.indexOfScalarPos(u8, data, i, '>') orelse return error.InvalidMagic;
                    rule.indent = try std.fmt.parseInt(u32, data[i..gt], 10);
                    i = gt;
                }
                const equals = std.mem.indexOfScalarPos(u8, data, i, '=') orelse return error.InvalidMagic;
                rule.start = try std.fmt.parseInt(usize, data[i + 1 .. equals], 10);
                i = equals + 1;
                if (i + 2 > data.len) return error.InvalidMagic;
                const len = std.mem.readInt(u16, data[i..][0..2], .big);
                i += 2;
                if (i + len > data.len) return error.InvalidMagic;
                rule.value = data[i .. i + len];
                i += len;
                if (i < data.len and data[i] == '&') {
                    if (i + 1 + len > data.len) return error.InvalidMagic;
                    rule.mask = data[i + 1 .. i + 1 + len];
                    i += 1 + len;
                }
                var word: usize = 1;
                if (i < data.len and data[i] == '~') {
                    const end = std.mem.indexOfAnyPos(u8, data, i + 1, "+\n") orelse return error.InvalidMagic;
                    word = try std.fmt.parseInt(usize, data[i + 1 .. end], 10);
                    i = end;
                }
                if (i < data.len and data[i] == '+') {
                    const end = std.mem.indexOfScalarPos(u8, data, i + 1, '\n') orelse return error.InvalidMagic;
                    rule.range = try std.fmt.parseInt(usize, data[i + 1 .. end], 10);
                    i = end;
                }
                if (i >= data.len or data[i] != '\n') return error.InvalidMagic;
                i += 1;
                // Values are big-endian words; this host is little-endian.
                if (word == 2 or word == 4) {
                    rule.value = try swapWords(a, rule.value, word);
                    if (rule.mask) |mask| rule.mask = try swapWords(a, mask, word);
                }
                self.sniff_len = @max(self.sniff_len, rule.start + rule.range - 1 + rule.value.len);
                try rules.append(a, rule);
            }
            const match: Match = .{ .priority = priority, .mime = mime, .rules = try rules.toOwnedSlice(a) };
            var at: usize = self.magic.items.len;
            for (self.magic.items, 0..) |existing, index| if (existing.priority < priority) {
                at = index;
                break;
            };
            try self.magic.insert(a, at, match);
        }
    }

    fn swapWords(a: std.mem.Allocator, value: []const u8, word: usize) ![]const u8 {
        const out = try a.dupe(u8, value);
        var i: usize = 0;
        while (i + word <= out.len) : (i += word) std.mem.reverse(u8, out[i .. i + word]);
        return out;
    }

    pub fn unalias(self: *const Database, mime: []const u8) []const u8 {
        return self.aliases.get(mime) orelse mime;
    }

    /// Whether `mime` is `base` or derives from it, as xdg_mime_mime_type_subclass.
    pub fn isA(self: *const Database, mime: []const u8, base: []const u8) bool {
        return self.subclass(self.unalias(mime), self.unalias(base), 0);
    }

    fn subclass(self: *const Database, mime: []const u8, base: []const u8, depth: u32) bool {
        if (std.mem.eql(u8, mime, base)) return true;
        if (std.mem.endsWith(u8, base, "/*")) {
            const media = base[0 .. base.len - 1];
            if (std.mem.startsWith(u8, mime, media)) return true;
        }
        if (std.mem.eql(u8, base, "text/plain") and std.mem.startsWith(u8, mime, "text/")) return true;
        if (std.mem.eql(u8, base, unknown) and !std.mem.startsWith(u8, mime, "inode/")) return true;
        if (depth > 32) return false;
        const list = self.parents.get(mime) orelse return false;
        for (list.items) |parent| if (self.subclass(self.unalias(parent), base, depth + 1)) return true;
        return false;
    }

    /// The type and its declared ancestors, unaliased, breadth first.
    pub fn ancestry(self: *const Database, a: std.mem.Allocator, mime: []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        try list.append(a, self.unalias(mime));
        var i: usize = 0;
        while (i < list.items.len) : (i += 1) {
            const parents = self.parents.get(list.items[i]) orelse continue;
            for (parents.items) |parent| {
                const value = self.unalias(parent);
                for (list.items) |existing| {
                    if (std.mem.eql(u8, existing, value)) break;
                } else try list.append(a, value);
            }
        }
        return list.toOwnedSlice(a);
    }

    /// Types whose globs match a file name, best first, as xdgmime returns them.
    pub fn fromName(self: *const Database, name: []const u8, out: *[10][]const u8) usize {
        var lower_buffer: [std.fs.max_name_bytes]u8 = undefined;
        if (name.len > lower_buffer.len) return 0;
        const lower = std.ascii.lowerString(&lower_buffer, name);
        for (self.literals.items) |glob| if (std.mem.eql(u8, glob.pattern, name)) {
            out[0] = glob.mime;
            return 1;
        };
        for (self.literals.items) |glob| if (!glob.case_sensitive and std.mem.eql(u8, glob.pattern, lower)) {
            out[0] = glob.mime;
            return 1;
        };
        var found: [10]Weighted = undefined;
        var count = self.suffixMatches(lower, false, &found, 0);
        if (count < 2) count = self.suffixMatches(name, true, &found, count);
        if (count < 2) for (self.patterns.items) |glob| {
            if (count == found.len) break;
            if (fnmatch(glob.pattern, name, !glob.case_sensitive)) {
                found[count] = .{ .mime = glob.mime, .weight = glob.weight };
                count += 1;
            }
        };
        // Duplicates keep their highest weight.
        var unique: usize = 0;
        outer: for (found[0..count]) |item| {
            for (found[0..unique]) |*kept| if (std.mem.eql(u8, kept.mime, item.mime)) {
                kept.weight = @max(kept.weight, item.weight);
                continue :outer;
            };
            found[unique] = item;
            unique += 1;
        }
        std.sort.insertion(Weighted, found[0..unique], {}, struct {
            fn heavier(_: void, left: Weighted, right: Weighted) bool {
                return left.weight > right.weight;
            }
        }.heavier);
        for (found[0..unique], 0..) |item, i| out[i] = item.mime;
        return unique;
    }

    const Weighted = struct { mime: []const u8, weight: u32 };

    /// The globs of the longest suffix of `name` that has any: the
    /// case-insensitive pass sees the lower-cased name and only globs without
    /// the "cs" flag, the case-sensitive pass sees every glob.
    fn suffixMatches(self: *const Database, name: []const u8, case_sensitive_check: bool, found: *[10]Weighted, start: usize) usize {
        var longest: usize = 0;
        for (self.suffixes.items) |glob| {
            if (!case_sensitive_check and glob.case_sensitive) continue;
            const suffix = glob.pattern[1..];
            if (suffix.len > name.len or suffix.len < longest) continue;
            if (!std.mem.eql(u8, name[name.len - suffix.len ..], suffix)) continue;
            longest = suffix.len;
        }
        if (longest == 0) return start;
        var count = start;
        for (self.suffixes.items) |glob| {
            if (count == found.len) break;
            if (!case_sensitive_check and glob.case_sensitive) continue;
            const suffix = glob.pattern[1..];
            if (suffix.len != longest or !std.mem.eql(u8, name[name.len - suffix.len ..], suffix)) continue;
            found[count] = .{ .mime = glob.mime, .weight = glob.weight };
            count += 1;
        }
        return count;
    }

    /// The magic match for leading file data, as xdg_mime_get_mime_type_for_data.
    pub fn fromData(self: *const Database, data: []const u8) struct { mime: []const u8, priority: u32 } {
        if (data.len == 0) return .{ .mime = empty, .priority = 100 };
        for (self.magic.items) |match| if (level(match.rules, 0, data, 0)) return .{ .mime = match.mime, .priority = match.priority };
        return .{ .mime = unknown, .priority = 0 };
    }

    fn level(rules: []const Rule, start: usize, data: []const u8, indent: u32) bool {
        var i = start;
        while (i < rules.len and rules[i].indent == indent) {
            if (compare(rules[i], data)) {
                if (i + 1 >= rules.len or rules[i + 1].indent <= indent) return true;
                if (level(rules, i + 1, data, indent + 1)) return true;
            }
            i += 1;
            while (i < rules.len and rules[i].indent > indent) i += 1;
        }
        return false;
    }

    fn compare(rule: Rule, data: []const u8) bool {
        var offset = rule.start;
        while (offset < rule.start + rule.range) : (offset += 1) {
            if (offset + rule.value.len > data.len) return false;
            const window = data[offset..][0..rule.value.len];
            if (rule.mask) |mask| {
                for (window, rule.value, mask) |byte, want, bits| {
                    if (byte & bits != want & bits) break;
                } else return true;
            } else if (std.mem.eql(u8, window, rule.value)) return true;
        }
        return false;
    }

    /// g_content_type_guess: `uncertain` reports when sniffing more data could help.
    pub fn guess(self: *const Database, name: ?[]const u8, data: ?[]const u8, uncertain: ?*bool) []const u8 {
        var names: [10][]const u8 = undefined;
        const count = if (name) |value| self.fromName(std.fs.path.basename(value), &names) else 0;
        if (uncertain) |flag| flag.* = false;
        if (count == 1) return names[0];
        var sniffed: []const u8 = unknown;
        var priority: u32 = 0;
        if (data) |bytes| {
            const result = self.fromData(bytes);
            sniffed = result.mime;
            priority = result.priority;
            if (std.mem.eql(u8, sniffed, unknown) and looksLikeText(bytes)) sniffed = "text/plain";
            // A desktop file is never recognized by content alone.
            if (name != null and std.mem.eql(u8, sniffed, "application/x-desktop")) sniffed = "text/plain";
        }
        if (count == 0) {
            if (std.mem.eql(u8, sniffed, unknown)) if (uncertain) |flag| {
                flag.* = true;
            };
            return sniffed;
        }
        if (!std.mem.eql(u8, sniffed, unknown)) {
            if (priority >= 80) return sniffed;
            for (names[0..count]) |candidate| if (self.isA(candidate, sniffed)) return candidate;
        }
        if (uncertain) |flag| flag.* = true;
        return names[0];
    }

    /// The content type GIO reports for a file: by name, then by up to the
    /// sniff length of its contents when the name is not conclusive.
    pub fn forFile(self: *const Database, path: []const u8) []const u8 {
        var name: [std.fs.max_path_bytes:0]u8 = undefined;
        if (path.len >= name.len) return unknown;
        @memcpy(name[0..path.len], path);
        name[path.len] = 0;
        var info: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, &name, 0, .{ .TYPE = true, .SIZE = true }, &info)) != .SUCCESS) {
            // A dangling link is described as the link itself.
            if (linux.errno(linux.statx(linux.AT.FDCWD, &name, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &info)) == .SUCCESS and linux.S.ISLNK(info.mode)) return "inode/symlink";
            return unknown;
        }
        if (linux.S.ISDIR(info.mode)) return "inode/directory";
        if (linux.S.ISCHR(info.mode)) return "inode/chardevice";
        if (linux.S.ISBLK(info.mode)) return "inode/blockdevice";
        if (linux.S.ISFIFO(info.mode)) return "inode/fifo";
        if (linux.S.ISSOCK(info.mode)) return "inode/socket";
        // Empty files are never sniffed: /proc and /sys files report size zero.
        if (info.size == 0) return empty;
        var uncertain = false;
        const by_name = self.guess(path, null, &uncertain);
        if (!uncertain) return by_name;
        var buffer: [4096]u8 = undefined;
        const limit = if (self.sniff_len == 0 or self.sniff_len > buffer.len) buffer.len else self.sniff_len;
        const data = readHead(path, buffer[0..limit]) orelse return by_name;
        return self.guess(path, data, null);
    }
};

fn readHead(path: []const u8, buffer: []u8) ?[]const u8 {
    var name: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= name.len) return null;
    @memcpy(name[0..path.len], path);
    name[path.len] = 0;
    const opened = linux.openat(linux.AT.FDCWD, &name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var len: usize = 0;
    while (len < buffer.len) {
        const got = linux.read(fd, buffer[len..].ptr, buffer.len - len);
        switch (linux.errno(got)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return null,
        }
        if (got == 0) break;
        len += got;
    }
    return buffer[0..len];
}

/// GIO's test: no control characters other than whitespace and backspace.
fn looksLikeText(data: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(data)) {
        // A sequence cut off at the end of the sample still counts as text.
        var end = data.len;
        while (end > 0 and end + 4 > data.len and !std.unicode.utf8ValidateSlice(data[0..end])) end -= 1;
        if (end + 4 <= data.len or !std.unicode.utf8ValidateSlice(data[0..end])) return false;
    }
    for (data) |byte| if (std.ascii.isControl(byte) and !std.ascii.isWhitespace(byte) and byte != 0x08) return false;
    return true;
}

/// fnmatch without flags beyond case folding: * ? and [...] classes.
pub fn fnmatch(pattern: []const u8, name: []const u8, fold: bool) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pattern.len) switch (pattern[p]) {
            '*' => {
                star_p = p;
                star_n = n;
                p += 1;
                continue;
            },
            '?' => {
                p += 1;
                n += 1;
                continue;
            },
            '[' => if (std.mem.indexOfScalarPos(u8, pattern, p + 1, ']')) |close| {
                var set = pattern[p + 1 .. close];
                const negate = set.len > 0 and (set[0] == '!' or set[0] == '^');
                if (negate) set = set[1..];
                var hit = false;
                var i: usize = 0;
                while (i < set.len) : (i += 1) {
                    const low = set[i];
                    var high = low;
                    if (i + 2 < set.len and set[i + 1] == '-') {
                        high = set[i + 2];
                        i += 2;
                    }
                    const byte = name[n];
                    if ((byte >= low and byte <= high) or (fold and std.ascii.toLower(byte) >= std.ascii.toLower(low) and std.ascii.toLower(byte) <= std.ascii.toLower(high))) hit = true;
                }
                if (hit != negate) {
                    p = close + 1;
                    n += 1;
                    continue;
                }
            },
            else => |byte| if (byte == name[n] or (fold and std.ascii.toLower(byte) == std.ascii.toLower(name[n]))) {
                p += 1;
                n += 1;
                continue;
            },
        };
        const star = star_p orelse return false;
        p = star + 1;
        star_n += 1;
        n = star_n;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn loadShared() ?*Database {
    return Database.load(std.heap.page_allocator) catch null;
}

/// The process's database, loaded once on first use.
pub fn shared() ?*const Database {
    return util.Lazy(?*Database, loadShared).get().*;
}

test "globs, magic and subclasses" {
    try std.testing.expect(fnmatch("*.tar.gz", "a.tar.gz", false));
    try std.testing.expect(fnmatch("[Mm]akefile", "makefile", false));
    try std.testing.expect(fnmatch("README*", "readme.md", true));
    try std.testing.expect(!fnmatch("*.c", "a.cc", false));
    try std.testing.expect(!fnmatch("x?", "x", false));
    try std.testing.expect(looksLikeText("plain\ttext\n"));
    try std.testing.expect(!looksLikeText("bin\x00ary"));
}

test "content types match GIO" {
    const glib = struct {
        extern fn g_content_type_guess(filename: ?[*:0]const u8, data: ?[*]const u8, size: usize, uncertain: ?*c_int) [*:0]u8;
        extern fn g_content_type_is_a(mime: [*:0]const u8, base: [*:0]const u8) c_int;
        extern fn g_content_type_from_mime_type(mime: [*:0]const u8) ?[*:0]u8;
        extern fn g_file_new_for_path(path: [*:0]const u8) *anyopaque;
        extern fn g_file_query_info(file: *anyopaque, attributes: [*:0]const u8, flags: c_int, cancellable: ?*anyopaque, err: ?*anyopaque) ?*anyopaque;
        extern fn g_file_info_get_content_type(info: *anyopaque) ?[*:0]const u8;
        extern fn g_object_unref(object: ?*anyopaque) void;
        extern fn g_free(mem: ?*anyopaque) void;
    };
    const a = std.testing.allocator;
    const db = shared() orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    // Names alone: every glob's own example plus mixed case and conflicts.
    var names: std.ArrayList([:0]const u8) = .empty;
    for (db.literals.items) |glob| try names.append(scratch, try scratch.dupeSentinel(u8, glob.pattern, 0));
    for (db.suffixes.items) |glob| {
        try names.append(scratch, try std.fmt.allocPrintSentinel(scratch, "file{s}", .{glob.pattern[1..]}, 0));
        try names.append(scratch, try std.fmt.allocPrintSentinel(scratch, "FILE{s}", .{try std.ascii.allocUpperString(scratch, glob.pattern[1..])}, 0));
    }
    for ([_][:0]const u8{ "Makefile", "makefile", "README", "a.tar.gz", "x.in", "core", "noextension", ".bashrc", "a.desktop" }) |name| try names.append(scratch, name);
    for (names.items) |name| {
        var uncertain: c_int = 0;
        const expected = glib.g_content_type_guess(name, null, 0, &uncertain);
        defer glib.g_free(expected);
        var ours_uncertain = false;
        const ours = db.guess(name, null, &ours_uncertain);
        std.testing.expectEqualStrings(std.mem.span(expected), ours) catch |err| {
            std.debug.print("guess({s})\n", .{name});
            return err;
        };
        std.testing.expectEqual(uncertain != 0, ours_uncertain) catch |err| {
            std.debug.print("uncertain({s}) = {s}\n", .{ name, ours });
            return err;
        };
    }
    // Real files: names and contents together, as file listings see them.
    var directories: std.ArrayList([]const u8) = .empty;
    // DESKTOP_MIME_TEST_DIRS adds colon-separated directories for a broader comparison.
    if (util.env("DESKTOP_MIME_TEST_DIRS")) |extra| {
        var parts = std.mem.splitScalar(u8, extra, ':');
        while (parts.next()) |part| if (part.len > 0) try directories.append(scratch, part);
    }
    for ([_][]const u8{ "/etc", "/dev", "/run/user", "/run/current-system/sw/bin", "/run/current-system/sw/share/icons/hicolor/48x48/apps", "/run/current-system/sw/share/applications", "/run/current-system/sw/lib", "/run/current-system/sw/share/doc" }) |directory| try directories.append(scratch, directory);
    for (directories.items) |directory| {
        const entries = paths.list(scratch, directory) catch continue;
        for (entries) |entry| {
            const full = try std.fmt.allocPrintSentinel(scratch, "{s}/{s}", .{ directory, entry.name }, 0);
            const kind = paths.kind(full);
            if (kind == .missing) continue;
            const file = glib.g_file_new_for_path(full);
            defer glib.g_object_unref(file);
            const info = glib.g_file_query_info(file, "standard::content-type", 0, null, null) orelse continue;
            defer glib.g_object_unref(info);
            const expected = std.mem.span(glib.g_file_info_get_content_type(info) orelse continue);
            std.testing.expectEqualStrings(expected, db.forFile(full)) catch |err| {
                std.debug.print("content type of {s}\n", .{full});
                return err;
            };
        }
    }
    // Hierarchy over every type pair that matters to filters.
    const bases = [_][:0]const u8{ "text/plain", "application/octet-stream", "image/*", "text/*", "application/xml", "application/zip", "application/javascript", "image/svg+xml", "inode/directory" };
    var types: std.ArrayList([:0]const u8) = .empty;
    for (db.suffixes.items) |glob| try types.append(scratch, try scratch.dupeSentinel(u8, glob.mime, 0));
    var aliases = db.aliases.iterator();
    while (aliases.next()) |alias| try types.append(scratch, try scratch.dupeSentinel(u8, alias.key_ptr.*, 0));
    for (types.items) |mime| {
        for (bases) |base| {
            std.testing.expectEqual(glib.g_content_type_is_a(mime, base) != 0, db.isA(mime, base)) catch |err| {
                std.debug.print("is_a({s}, {s})\n", .{ mime, base });
                return err;
            };
        }
        const unaliased = glib.g_content_type_from_mime_type(mime).?;
        defer glib.g_free(unaliased);
        try std.testing.expectEqualStrings(std.mem.span(unaliased), db.unalias(mime));
    }
}
