//! Local file enumeration and portal filters. No GTK widget or filter objects.
//! Directories are read on a worker thread with the file information GIO's
//! local file enumerator reported, and results are delivered on the main loop.
const std = @import("std");
const linux = std.os.linux;
const c = @import("desktop-glib.zig");
const paths = @import("desktop-paths.zig");
const mime = @import("desktop-mime.zig");
const cast = c.__zig.cast;

pub const Entry = struct {
    name: [:0]const u8,
    label: [:0]const u8,
    content_type: ?[:0]const u8,
    directory: bool,
    hidden: bool,
    selected: bool = false,
    size: u64 = 0,
    modified: u64 = 0,
    sort_key: [:0]const u8 = "",
};
pub const Rule = struct { mime: bool, pattern: [:0]const u8 };
pub fn matches(entry: Entry, rules: []const Rule) bool {
    if (entry.directory or rules.len == 0) return true;
    for (rules) |rule| {
        if (!rule.mime) {
            if (simpleMatch(rule.pattern, entry.name)) return true;
        } else if (entry.content_type) |content_type| {
            const db = mime.shared() orelse continue;
            if (db.isA(content_type, rule.pattern)) return true;
        }
    }
    return false;
}

/// g_pattern_match_simple: `*` matches any run and `?` any one character.
fn simpleMatch(pattern: []const u8, name: []const u8) bool {
    const view = std.unicode.Utf8View.init(name) catch return false;
    var characters: std.ArrayList(u21) = .empty;
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |point| characters.append(fixed.allocator(), point) catch return false;
    return matchFrom(pattern, characters.items);
}

fn matchFrom(pattern: []const u8, name: []const u21) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            star_n = n;
            p += 1;
            continue;
        }
        if (p < pattern.len) {
            const length = std.unicode.utf8ByteSequenceLength(pattern[p]) catch 1;
            const point = if (pattern[p] == '?') name[n] else std.unicode.utf8Decode(pattern[p..@min(pattern.len, p + length)]) catch pattern[p];
            if (point == name[n]) {
                p += if (pattern[p] == '?') 1 else length;
                n += 1;
                continue;
            }
        }
        const star = star_p orelse return false;
        p = star + 1;
        star_n += 1;
        n = star_n;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// A scan owns its strings and remains alive until its final callback. Cancellation
/// still invokes completion, so callers can release their asynchronous reference.
pub const Scan = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    path: [:0]const u8,
    cancelled: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    context: ?*anyopaque,
    completed: *const fn (?*anyopaque, *Scan, ?anyerror) void,

    pub fn start(allocator: std.mem.Allocator, path: [:0]const u8, context: ?*anyopaque, completed: *const fn (?*anyopaque, *Scan, ?anyerror) void) !*Scan {
        const self = try allocator.create(Scan);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .arena = .init(allocator), .path = undefined, .context = context, .completed = completed };
        errdefer self.arena.deinit();
        self.path = try self.arena.allocator().dupeSentinel(u8, path, 0);
        const thread = try std.Thread.spawn(.{}, work, .{self});
        thread.detach();
        return self;
    }

    pub fn cancel(self: *Scan) void {
        self.cancelled.store(true, .release);
    }

    pub fn destroy(self: *Scan) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn work(self: *Scan) void {
        self.failure = if (self.read()) |_| null else |err| err;
        if (self.cancelled.load(.acquire)) self.failure = error.DirectoryUnavailable;
        if (self.failure == null) std.mem.sort(Entry, self.entries.items, {}, less);
        _ = c.g_idle_add(&deliver, self);
    }

    fn deliver(data: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Scan, data);
        self.completed(self.context, self, self.failure);
        return 0;
    }

    fn read(self: *Scan) !void {
        const a = self.arena.allocator();
        const listing = paths.list(a, self.path) catch return error.DirectoryUnavailable;
        // Names listed in the directory's .hidden file are hidden, as in GIO.
        const hidden_list = paths.readFile(a, try std.fmt.allocPrint(a, "{s}/.hidden", .{std.mem.trimEnd(u8, self.path, "/")}), 1 << 20) catch "";
        const db = mime.shared();
        for (listing) |item| {
            if (self.cancelled.load(.acquire)) return error.Cancelled;
            // A bounded model avoids unbounded allocations from huge directories.
            if (self.entries.items.len >= 65536) return error.DirectoryTooLarge;
            const full = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ std.mem.trimEnd(u8, self.path, "/"), item.name }, 0);
            var info: linux.Statx = undefined;
            const mask: linux.STATX = .{ .TYPE = true, .SIZE = true, .MTIME = true };
            if (linux.errno(linux.statx(linux.AT.FDCWD, full, 0, mask, &info)) != .SUCCESS) {
                // A dangling link is listed as the link itself.
                if (linux.errno(linux.statx(linux.AT.FDCWD, full, linux.AT.SYMLINK_NOFOLLOW, mask, &info)) != .SUCCESS) continue;
            }
            const label = try displayName(a, item.name);
            try self.entries.append(a, .{
                .name = item.name,
                .label = label,
                .content_type = if (db) |database| try a.dupeSentinel(u8, database.forFile(full), 0) else null,
                .directory = linux.S.ISDIR(info.mode),
                .hidden = item.name[0] == '.' or listed(hidden_list, item.name),
                .size = info.size,
                .modified = @intCast(@max(0, info.mtime.sec)),
                .sort_key = try @import("desktop-unicode.zig").collateKeyForFilename(a, label),
            });
        }
    }

    fn less(_: void, left: Entry, right: Entry) bool {
        if (left.directory != right.directory) return left.directory;
        if (left.sort_key.len > 0 and right.sort_key.len > 0) return std.mem.lessThan(u8, left.sort_key, right.sort_key);
        return std.ascii.lessThanIgnoreCase(left.name, right.name);
    }
};

fn listed(list: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), name)) return true;
    return false;
}

/// The file name as g_filename_display_name shows it: invalid UTF-8 becomes U+FFFD.
fn displayName(a: std.mem.Allocator, name: []const u8) ![:0]const u8 {
    if (std.unicode.utf8ValidateSlice(name)) return a.dupeSentinel(u8, name, 0);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < name.len) {
        const length = std.unicode.utf8ByteSequenceLength(name[i]) catch 0;
        if (length > 0 and i + length <= name.len and std.unicode.utf8ValidateSlice(name[i .. i + length])) {
            try out.appendSlice(a, name[i .. i + length]);
            i += length;
        } else {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSliceSentinel(a, 0);
}

test "file filters preserve directories and combine glob and MIME rules" {
    const expect = std.testing.expect;
    const entry: Entry = .{ .name = "日本語.txt", .label = "日本語.txt", .content_type = "text/plain", .directory = false, .hidden = false };
    try expect(matches(entry, &.{}));
    try expect(matches(entry, &.{.{ .mime = false, .pattern = "*.txt" }}));
    try expect(matches(entry, &.{.{ .mime = false, .pattern = "???.txt" }}));
    try expect(!matches(entry, &.{.{ .mime = false, .pattern = "*.png" }}));
    try expect(!matches(entry, &.{.{ .mime = false, .pattern = "[日]*" }}));
    try expect(matches(entry, &.{ .{ .mime = false, .pattern = "*.png" }, .{ .mime = true, .pattern = "text/plain" } }));
    var folder = entry;
    folder.directory = true;
    try expect(matches(folder, &.{.{ .mime = false, .pattern = "*.png" }}));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\u{FFFD}b", try displayName(arena.allocator(), "a\xffb"));
}

test "simple patterns match GLib" {
    const glib = struct {
        extern fn g_pattern_match_simple(pattern: [*:0]const u8, string: [*:0]const u8) c_int;
    };
    const patterns = [_][:0]const u8{ "*", "*.txt", "?.txt", "a*b*c", "*.TXT", "[ab]*", "日*", "*語.txt", "**", "?", "" };
    const names = [_][:0]const u8{ "a.txt", "ab.txt", "abc", "aXbYc", "日本語.txt", "[ab]x", "", "x" };
    for (patterns) |pattern| for (names) |name| {
        std.testing.expectEqual(glib.g_pattern_match_simple(pattern, name) != 0, simpleMatch(pattern, name)) catch |err| {
            std.debug.print("match({s}, {s})\n", .{ pattern, name });
            return err;
        };
    };
}
