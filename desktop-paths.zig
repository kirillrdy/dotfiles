//! User directories, file queries and file URIs in Zig, with the semantics the
//! desktop previously took from GLib: XDG base directories, xdg-user-dirs,
//! lexical path canonicalization and RFC 8089 file URIs. File access uses
//! Linux system calls directly, so it works without a std.Io instance.
const std = @import("std");
const linux = std.os.linux;
const libc = @import("desktop-libc.zig");
const util = @import("desktop-util.zig");

/// The user's home directory: $HOME, else the password database, else "/".
pub fn home() [:0]const u8 {
    return dirs().home;
}

/// The login name from the password database.
pub fn userName() [:0]const u8 {
    return dirs().user_name;
}

/// The full name from the password database's GECOS field, or "".
pub fn realName() [:0]const u8 {
    return dirs().real_name;
}

/// $XDG_DATA_HOME or ~/.local/share.
pub fn dataHome() [:0]const u8 {
    return dirs().data;
}

/// $XDG_CONFIG_HOME or ~/.config.
pub fn configHome() [:0]const u8 {
    return dirs().config;
}

/// $XDG_CACHE_HOME or ~/.cache.
pub fn cacheHome() [:0]const u8 {
    return dirs().cache;
}

/// $XDG_RUNTIME_DIR, else the cache directory.
pub fn runtimeDir() [:0]const u8 {
    return dirs().runtime;
}

/// The xdg-user-dirs directories, in GLib's GUserDirectory order.
pub const Special = enum { desktop, documents, download, music, pictures, public_share, templates, videos };

/// A directory from user-dirs.dirs. Only the desktop has a default (~/Desktop).
pub fn special(directory: Special) ?[:0]const u8 {
    return dirs().special[@backingInt(directory)];
}

const Dirs = struct {
    home: [:0]const u8,
    user_name: [:0]const u8,
    real_name: [:0]const u8,
    data: [:0]const u8,
    config: [:0]const u8,
    cache: [:0]const u8,
    runtime: [:0]const u8,
    special: [@typeInfo(Special).@"enum".field_names.len]?[:0]const u8,
};

fn loadDirs() Dirs {
    // Process-lifetime strings, like GLib's.
    const a = std.heap.page_allocator;
    const user = libc.getpwuid(libc.getuid());
    const passwd_field = struct {
        fn get(value: [*c]u8) [:0]const u8 {
            return if (value == null) "" else std.mem.span(value);
        }
    }.get;
    const home_dir = nonEmpty("HOME") orelse if (user != null and passwd_field(user.*.pw_dir).len > 0) passwd_field(user.*.pw_dir) else "/";
    const name = if (user != null) passwd_field(user.*.pw_name) else "";
    const gecos = if (user != null) passwd_field(user.*.pw_gecos) else "";
    const full_name = std.mem.sliceTo(gecos, ',');
    const cache = nonEmpty("XDG_CACHE_HOME") orelse join(a, home_dir, ".cache");
    const config = nonEmpty("XDG_CONFIG_HOME") orelse join(a, home_dir, ".config");
    var result: Dirs = .{
        .home = home_dir,
        .user_name = if (name.len > 0) name else "somebody",
        .real_name = a.dupeSentinel(u8, full_name, 0) catch "",
        .data = nonEmpty("XDG_DATA_HOME") orelse join(a, home_dir, ".local/share"),
        .config = config,
        .cache = cache,
        .runtime = nonEmpty("XDG_RUNTIME_DIR") orelse cache,
        .special = @splat(null),
    };
    const file = join(a, config, "user-dirs.dirs");
    if (readFile(a, file, 64 * 1024)) |contents| {
        parseUserDirs(a, home_dir, contents, &result.special);
    } else |_| {}
    if (result.special[@backingInt(Special.desktop)] == null) result.special[@backingInt(Special.desktop)] = join(a, home_dir, "Desktop");
    return result;
}

const dirs_cache = util.Lazy(Dirs, loadDirs);
fn dirs() *const Dirs {
    return dirs_cache.get();
}

fn nonEmpty(name: [:0]const u8) ?[:0]const u8 {
    const value = util.env(name) orelse return null;
    return if (value.len > 0) value else null;
}

fn join(a: std.mem.Allocator, base: []const u8, child: []const u8) [:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), child }, 0) catch "/";
}

/// Reads lines such as XDG_PICTURES_DIR="$HOME/Pictures", as GLib does.
fn parseUserDirs(a: std.mem.Allocator, home_dir: []const u8, contents: []const u8, out: *[8]?[:0]const u8) void {
    const keys = [_][]const u8{ "DESKTOP", "DOCUMENTS", "DOWNLOAD", "MUSIC", "PICTURES", "PUBLICSHARE", "TEMPLATES", "VIDEOS" };
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trimStart(u8, raw, " \t");
        if (!std.mem.startsWith(u8, line, "XDG_")) continue;
        line = line[4..];
        const index = for (keys, 0..) |key, i| {
            if (std.mem.startsWith(u8, line, key) and std.mem.startsWith(u8, line[key.len..], "_DIR")) break i;
        } else continue;
        line = std.mem.trimStart(u8, line[keys[index].len + 4 ..], " \t");
        if (line.len == 0 or line[0] != '=') continue;
        line = std.mem.trimStart(u8, line[1..], " \t");
        if (line.len > 0 and line[0] == '"') {
            line = line[1..];
            line = line[0 .. std.mem.indexOfScalar(u8, line, '"') orelse continue];
        } else line = std.mem.trimEnd(u8, line, " \t\r");
        var relative = false;
        if (std.mem.startsWith(u8, line, "$HOME")) {
            line = line[5..];
            relative = true;
        } else if (line.len == 0 or line[0] != '/') continue;
        if (relative and line.len > 0 and line[0] != '/') continue;
        // Trailing slashes are dropped, but "/" stays "/".
        const trimmed = std.mem.trimEnd(u8, line, "/");
        const path = if (relative)
            std.fmt.allocPrintSentinel(a, "{s}{s}", .{ std.mem.trimEnd(u8, home_dir, "/"), trimmed }, 0) catch continue
        else
            a.dupeSentinel(u8, if (trimmed.len == 0) "/" else trimmed, 0) catch continue;
        out[index] = if (path.len == 0) "/" else path;
    }
}

pub const Kind = enum { missing, file, directory, other };

/// The type of `path`, following symbolic links.
pub fn kind(path: []const u8) Kind {
    var name: [std.fs.max_path_bytes:0]u8 = undefined;
    const z = terminate(path, &name) orelse return .missing;
    var info: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .TYPE = true }, &info)) != .SUCCESS) return .missing;
    if (linux.S.ISDIR(info.mode)) return .directory;
    if (linux.S.ISREG(info.mode)) return .file;
    return .other;
}

pub fn exists(path: []const u8) bool {
    return kind(path) != .missing;
}

pub fn isDirectory(path: []const u8) bool {
    return kind(path) == .directory;
}

fn terminate(path: []const u8, buffer: *[std.fs.max_path_bytes:0]u8) ?[*:0]const u8 {
    if (path.len >= buffer.len or std.mem.indexOfScalar(u8, path, 0) != null) return null;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return buffer;
}

/// The names in a directory, without "." and "..", in directory order.
pub fn list(a: std.mem.Allocator, path: []const u8) ![]Listed {
    var name: [std.fs.max_path_bytes:0]u8 = undefined;
    const z = terminate(path, &name) orelse return error.InvalidPath;
    const opened = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.FileNotFound;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var entries: std.ArrayList(Listed) = .empty;
    errdefer {
        for (entries.items) |entry| a.free(entry.name);
        entries.deinit(a);
    }
    var buffer: [16 * 1024]u8 align(8) = undefined;
    while (true) {
        const got = linux.getdents64(fd, &buffer, buffer.len);
        switch (linux.errno(got)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (got == 0) break;
        var offset: usize = 0;
        while (offset < got) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&buffer[offset]);
            const raw: [*:0]const u8 = @ptrCast(&buffer[offset + @offsetOf(linux.dirent64, "name")]);
            const entry_name = std.mem.span(raw);
            offset += entry.reclen;
            if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) continue;
            const kind_value: Kind = switch (entry.type) {
                linux.DT.DIR => .directory,
                linux.DT.REG => .file,
                linux.DT.UNKNOWN, linux.DT.LNK => .missing,
                else => .other,
            };
            const owned = try a.dupeSentinel(u8, entry_name, 0);
            errdefer a.free(owned);
            try entries.append(a, .{ .name = owned, .kind = kind_value, .resolved = kind_value != .missing });
        }
    }
    return entries.toOwnedSlice(a);
}

/// A directory entry. When `resolved` is false (symbolic links and file systems
/// without types), `kind` is unknown and the caller asks `kind()` for the target.
pub const Listed = struct { name: [:0]const u8, kind: Kind, resolved: bool };

/// Whether `path` is an executable regular file, following symbolic links.
pub fn isExecutable(path: []const u8) bool {
    var name: [std.fs.max_path_bytes:0]u8 = undefined;
    const z = terminate(path, &name) orelse return false;
    if (kind(path) != .file) return false;
    return linux.errno(linux.faccessat(linux.AT.FDCWD, z, linux.X_OK, 0)) == .SUCCESS;
}

/// Finds a program as g_find_program_for_path does: a path containing a slash
/// is used as given, otherwise each $PATH directory is searched.
pub fn findProgram(a: std.mem.Allocator, program: []const u8) ?[:0]u8 {
    if (program.len == 0) return null;
    if (std.mem.indexOfScalar(u8, program, '/') != null) {
        if (!isExecutable(program)) return null;
        return a.dupeSentinel(u8, program, 0) catch null;
    }
    const search = util.env("PATH") orelse "/bin:/usr/bin:.";
    var directories = std.mem.splitScalar(u8, search, ':');
    while (directories.next()) |directory| {
        const candidate = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ if (directory.len == 0) "." else directory, program }, 0) catch return null;
        if (isExecutable(candidate)) return candidate;
        a.free(candidate);
    }
    return null;
}

/// Creates `path` and any missing parents; succeeds if it is already a directory.
pub fn makeDirectories(path: []const u8, mode: u32) !void {
    if (path.len == 0) return error.InvalidPath;
    var name: [std.fs.max_path_bytes:0]u8 = undefined;
    _ = terminate(path, &name) orelse return error.InvalidPath;
    var end: usize = 1;
    while (end <= path.len) : (end += 1) {
        if (end < path.len and path[end] != '/') continue;
        if (path[end - 1] == '/') continue;
        const saved = name[end];
        name[end] = 0;
        defer name[end] = saved;
        switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, &name, mode))) {
            .SUCCESS, .EXIST => {},
            else => return error.CreateDirectoryFailed,
        }
    }
    if (!isDirectory(path)) return error.CreateDirectoryFailed;
}

/// Reads a whole file, including procfs files that report a zero size.
pub fn readFile(a: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var name: [std.fs.max_path_bytes:0]u8 = undefined;
    const z = terminate(path, &name) orelse return error.InvalidPath;
    const opened = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.FileNotFound;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(a);
    while (true) {
        if (data.items.len > limit) return error.FileTooBig;
        try data.ensureUnusedCapacity(a, 4096);
        const spare = data.unusedCapacitySlice();
        const got = linux.read(fd, spare.ptr, spare.len);
        switch (linux.errno(got)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (got == 0) break;
        data.items.len += got;
    }
    if (data.items.len > limit) return error.FileTooBig;
    return data.toOwnedSlice(a);
}

/// The target of a symbolic link, such as /proc/self/exe.
pub fn readLink(a: std.mem.Allocator, path: []const u8) ![:0]u8 {
    var name: [std.fs.max_path_bytes:0]u8 = undefined;
    const z = terminate(path, &name) orelse return error.InvalidPath;
    var target: [std.fs.max_path_bytes]u8 = undefined;
    const got = linux.readlinkat(linux.AT.FDCWD, z, &target, target.len);
    if (linux.errno(got) != .SUCCESS or got >= target.len) return error.ReadLinkFailed;
    return a.dupeSentinel(u8, target[0..got], 0);
}

/// Creates a new file named `prefix` plus six random characters, readable and
/// writable only by the user, like mkstemp. The caller closes the descriptor.
pub fn createTemporary(a: std.mem.Allocator, prefix: []const u8) !struct { fd: linux.fd_t, path: [:0]u8 } {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const path = try std.fmt.allocPrintSentinel(a, "{s}XXXXXX", .{prefix}, 0);
    errdefer a.free(path);
    for (0..100) |_| {
        var random: [6]u8 = undefined;
        if (linux.errno(linux.getrandom(&random, random.len, 0)) != .SUCCESS) return error.CreateFileFailed;
        for (random, path[prefix.len..]) |byte, *slot| slot.* = alphabet[byte % alphabet.len];
        const opened = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
        switch (linux.errno(opened)) {
            .SUCCESS => return .{ .fd = @intCast(opened), .path = path },
            .EXIST => continue,
            else => return error.CreateFileFailed,
        }
    }
    return error.CreateFileFailed;
}

/// Replaces a file's contents atomically and durably, as g_file_set_contents_full
/// with consistent and durable flags: a synced temporary file is renamed over it.
pub fn writeFileAtomic(a: std.mem.Allocator, path: []const u8, data: []const u8, mode: linux.mode_t) !void {
    const prefix = try std.fmt.allocPrint(a, "{s}.", .{path});
    defer a.free(prefix);
    const temporary = try createTemporary(a, prefix);
    defer a.free(temporary.path);
    var renamed = false;
    defer if (!renamed) {
        _ = linux.unlinkat(linux.AT.FDCWD, temporary.path, 0);
    };
    {
        defer _ = linux.close(temporary.fd);
        if (linux.errno(linux.fchmod(temporary.fd, mode)) != .SUCCESS) return error.WriteFailed;
        var written: usize = 0;
        while (written < data.len) {
            const result = linux.write(temporary.fd, data[written..].ptr, data.len - written);
            switch (linux.errno(result)) {
                .SUCCESS => written += result,
                .INTR => {},
                else => return error.WriteFailed,
            }
        }
        if (linux.errno(linux.fsync(temporary.fd)) != .SUCCESS) return error.WriteFailed;
    }
    var name: [std.fs.max_path_bytes:0]u8 = undefined;
    const target = terminate(path, &name) orelse return error.InvalidPath;
    if (linux.errno(linux.renameat(linux.AT.FDCWD, temporary.path, linux.AT.FDCWD, target)) != .SUCCESS) return error.WriteFailed;
    renamed = true;
}

/// Creates a new private directory named `prefix` plus six random characters
/// in $TMPDIR or /tmp, like g_dir_make_tmp.
pub fn createTemporaryDirectory(a: std.mem.Allocator, prefix: []const u8) ![:0]u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const base = util.env("TMPDIR") orelse "/tmp";
    const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}XXXXXX", .{ std.mem.trimEnd(u8, if (base.len > 0) base else "/tmp", "/"), prefix }, 0);
    errdefer a.free(path);
    for (0..100) |_| {
        var random: [6]u8 = undefined;
        if (linux.errno(linux.getrandom(&random, random.len, 0)) != .SUCCESS) return error.CreateDirectoryFailed;
        for (random, path[path.len - 6 ..]) |byte, *slot| slot.* = alphabet[byte % alphabet.len];
        switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, path, 0o700))) {
            .SUCCESS => return path,
            .EXIST => continue,
            else => return error.CreateDirectoryFailed,
        }
    }
    return error.CreateDirectoryFailed;
}

/// Resolves "." and ".." and repeated or trailing slashes without touching the
/// file system, as GLib does for file paths. Exactly two leading slashes stay,
/// as POSIX allows them a distinct meaning.
pub fn canonicalize(a: std.mem.Allocator, path: []const u8) ![:0]u8 {
    if (path.len == 0 or path[0] != '/') return error.RelativePath;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const leading = std.mem.indexOfNone(u8, path, "/") orelse path.len;
    try out.appendNTimes(a, '/', if (leading == 2) 2 else 1);
    const root = out.items.len;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (out.items.len > root) {
                const slash = std.mem.lastIndexOfScalar(u8, out.items[root..], '/');
                out.items.len = if (slash) |s| root + s else root;
            }
            continue;
        }
        if (out.items.len > root) try out.append(a, '/');
        try out.appendSlice(a, part);
    }
    return out.toOwnedSliceSentinel(a, 0);
}

/// A file:// URI for an absolute path, canonicalized and percent-encoded like
/// g_file_get_uri.
pub fn fileUri(a: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const canonical = try canonicalize(a, path);
    defer a.free(canonical);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "file://");
    for (canonical) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "!$&'()*+,-./:=@_~", byte) != null) {
            try out.append(a, byte);
        } else try out.print(a, "%{X:0>2}", .{byte});
    }
    return out.toOwnedSliceSentinel(a, 0);
}

/// The local path of a file: URI, like g_filename_from_uri: any host is
/// accepted, a query or fragment is dropped, and escaped slashes or NULs and
/// relative paths are rejected.
pub fn pathFromUri(a: std.mem.Allocator, uri: []const u8) ?[:0]u8 {
    return decodeFileUri(a, uri) catch null;
}

fn decodeFileUri(a: std.mem.Allocator, uri: []const u8) ![:0]u8 {
    if (uri.len < 6 or !std.ascii.eqlIgnoreCase(uri[0..5], "file:") or uri[5] != '/') return error.InvalidUri;
    var rest = uri[5..];
    if (std.mem.startsWith(u8, rest, "//")) {
        const slash = std.mem.indexOfScalarPos(u8, rest, 2, '/') orelse return error.InvalidUri;
        for (rest[2..slash]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.')) return error.InvalidUri;
        rest = rest[slash..];
    }
    // A query or fragment is not part of the path.
    rest = rest[0 .. std.mem.indexOfAny(u8, rest, "?#") orelse rest.len];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        var byte = rest[i];
        if (byte == '%') {
            if (i + 2 >= rest.len) return error.InvalidUri;
            byte = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch return error.InvalidUri;
            if (byte == 0 or byte == '/') return error.InvalidUri;
            i += 2;
        }
        try out.append(a, byte);
    }
    if (out.items.len == 0 or out.items[0] != '/') return error.InvalidUri;
    return out.toOwnedSliceSentinel(a, 0);
}

test "file URIs and canonical paths roundtrip" {
    const a = std.testing.allocator;
    const canonical_cases = [_][2][]const u8{
        .{ "/", "/" },
        .{ "/a//b/./c/../d/", "/a/b/d" },
        .{ "/..", "/" },
    };
    for (canonical_cases) |case| {
        const actual = try canonicalize(a, case[0]);
        defer a.free(actual);
        try std.testing.expectEqualStrings(case[1], actual);
    }
    for ([_][]const u8{ "/", "/home/user/Pictures/東京 #1?.png", "/tmp/50% off;x=[1]{2}<3>|\"4\"" }) |path| {
        const uri = try fileUri(a, path);
        defer a.free(uri);
        const back = pathFromUri(a, uri).?;
        defer a.free(back);
        try std.testing.expectEqualStrings(path, back);
    }
    const decoded = pathFromUri(a, "file:///a%20b").?;
    defer a.free(decoded);
    try std.testing.expectEqualStrings("/a b", decoded);
    const plain = pathFromUri(a, "file:/plain").?;
    defer a.free(plain);
    try std.testing.expectEqualStrings("/plain", plain);
    for ([_][]const u8{ "file:///a%2Fb", "file:///a%00b", "file://bad host/x", "file:relative", "http://x/y", "file:///%zz", "file:///a%2" }) |invalid| {
        try std.testing.expect(pathFromUri(a, invalid) == null);
    }
}

test "user directories parse like xdg-user-dirs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: [8]?[:0]const u8 = @splat(null);
    parseUserDirs(arena.allocator(), "/home/u",
        \\# comment
        \\XDG_DESKTOP_DIR="$HOME/Desktop"
        \\  XDG_PICTURES_DIR = "$HOME/Media/Pictures/"
        \\XDG_MUSIC_DIR="/srv/music"
        \\XDG_VIDEOS_DIR="$HOME"
        \\XDG_DOCUMENTS_DIR="relative"
        \\XDG_DOWNLOAD_DIR="$HOMEbad"
        \\XDG_PUBLICSHARE_DIR="/"
    , &out);
    try std.testing.expectEqualStrings("/home/u/Desktop", out[0].?);
    try std.testing.expect(out[1] == null);
    try std.testing.expect(out[2] == null);
    try std.testing.expectEqualStrings("/srv/music", out[3].?);
    try std.testing.expectEqualStrings("/home/u/Media/Pictures", out[4].?);
    try std.testing.expectEqualStrings("/", out[5].?);
    try std.testing.expectEqualStrings("/home/u", out[7].?);
}

test "files, links, directories and temporary files" {
    const a = std.testing.allocator;
    const base = try std.fmt.allocPrintSentinel(a, "{s}/desktop-paths-test-{d}", .{ runtimeDir(), linux.getpid() }, 0);
    defer a.free(base);
    const nested = try std.fmt.allocPrintSentinel(a, "{s}/a/b//c/", .{base}, 0);
    defer a.free(nested);
    try makeDirectories(nested, 0o700);
    try makeDirectories(nested, 0o700);
    try std.testing.expect(isDirectory(nested));
    const prefix = try std.fmt.allocPrint(a, "{s}/tmp-", .{base});
    defer a.free(prefix);
    const temporary = try createTemporary(a, prefix);
    defer a.free(temporary.path);
    _ = linux.write(temporary.fd, "hello", 5);
    _ = linux.close(temporary.fd);
    try std.testing.expectEqual(Kind.file, kind(temporary.path));
    const contents = try readFile(a, temporary.path, 1024);
    defer a.free(contents);
    try std.testing.expectEqualStrings("hello", contents);
    try std.testing.expectError(error.FileTooBig, readFile(a, temporary.path, 2));
    const exe = try readLink(a, "/proc/self/exe");
    defer a.free(exe);
    try std.testing.expect(exe[0] == '/');
    const stat = try readFile(a, "/proc/self/stat", 1 << 20);
    defer a.free(stat);
    try std.testing.expect(stat.len > 0);
    try std.testing.expectEqual(Kind.missing, kind("/nonexistent/desktop-paths"));
    _ = linux.unlinkat(linux.AT.FDCWD, temporary.path, 0);
    for ([_][]const u8{ "/a/b/c", "/a/b", "/a" }) |suffix| {
        const dir = try std.fmt.allocPrintSentinel(a, "{s}{s}", .{ base, suffix }, 0);
        defer a.free(dir);
        _ = linux.unlinkat(linux.AT.FDCWD, dir, linux.AT.REMOVEDIR);
    }
    _ = linux.unlinkat(linux.AT.FDCWD, base, linux.AT.REMOVEDIR);
}
