//! Directory change notification over inotify, in Zig, as GIO's directory
//! monitors provided it: any change inside a watched directory is reported,
//! and a directory that does not exist yet is polled for and reported once it
//! appears.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const linux = std.os.linux;

const events: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MODIFY | linux.IN.ATTRIB | linux.IN.CLOSE_WRITE |
    linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;

/// GIO looks for missing directories every four seconds.
const missing_poll_ms = 4000;

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fd: linux.fd_t,
    source: c_uint = 0,
    poll: c_uint = 0,
    directories: std.ArrayList(Directory) = .empty,
    changed: *const fn (?*anyopaque) void,
    context: ?*anyopaque,

    const Directory = struct { path: [:0]u8, wd: ?i32 = null };

    /// `changed` runs on the main loop after directory contents change.
    pub fn create(a: std.mem.Allocator, io: std.Io, changed: *const fn (?*anyopaque) void, context: ?*anyopaque) !*Watcher {
        const opened = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(opened) != .SUCCESS) return error.WatchUnavailable;
        const self = a.create(Watcher) catch |err| {
            _ = linux.close(@intCast(opened));
            return err;
        };
        self.* = .{ .allocator = a, .io = io, .fd = @intCast(opened), .changed = changed, .context = context };
        self.source = mainloop.watch(io, self.fd, mainloop.IN, self, readable);
        return self;
    }

    pub fn destroy(self: *Watcher) void {
        if (self.source != 0) _ = mainloop.remove(self.io, self.source);
        if (self.poll != 0) _ = mainloop.remove(self.io, self.poll);
        _ = linux.close(self.fd);
        for (self.directories.items) |directory| self.allocator.free(directory.path);
        self.directories.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Watches a directory, which need not exist yet.
    pub fn watch(self: *Watcher, path: []const u8) !void {
        const owned = try self.allocator.dupeSentinel(u8, path, 0);
        errdefer self.allocator.free(owned);
        try self.directories.append(self.allocator, .{ .path = owned });
        const directory = &self.directories.items[self.directories.items.len - 1];
        if (!self.attach(directory)) self.pollMissing();
    }

    fn attach(self: *Watcher, directory: *Directory) bool {
        const added = linux.inotify_add_watch(self.fd, directory.path, events | linux.IN.ONLYDIR);
        if (linux.errno(added) != .SUCCESS) return false;
        directory.wd = @intCast(added);
        return true;
    }

    fn pollMissing(self: *Watcher) void {
        if (self.poll == 0) self.poll = mainloop.timeout(self.io, missing_poll_ms, self, checkMissing);
    }

    fn checkMissing(self: *Watcher) bool {
        var appeared = false;
        var still_missing = false;
        for (self.directories.items) |*directory| {
            if (directory.wd != null) continue;
            if (self.attach(directory)) appeared = true else still_missing = true;
        }
        if (appeared) self.changed(self.context);
        if (still_missing) return true;
        self.poll = 0;
        return false;
    }

    fn readable(self: *Watcher, _: c_int, _: u32) bool {
        var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        var any = false;
        while (true) {
            const got = linux.read(self.fd, &buffer, buffer.len);
            switch (linux.errno(got)) {
                .SUCCESS => {},
                .INTR => continue,
                else => break,
            }
            if (got == 0) break;
            var offset: usize = 0;
            while (offset + @sizeOf(linux.inotify_event) <= got) {
                const event: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[offset]));
                offset += @sizeOf(linux.inotify_event) + event.len;
                any = true;
                // A removed directory goes back to waiting for its return.
                if (event.mask & linux.IN.IGNORED != 0) for (self.directories.items) |*directory| {
                    if (directory.wd == event.wd) {
                        directory.wd = null;
                        self.pollMissing();
                    }
                };
            }
        }
        if (any) self.changed(self.context);
        return true;
    }
};


test "directory changes, deletion and late creation are reported" {
    const a = std.testing.allocator;
    const paths = @import("desktop-paths.zig");
    const Count = struct {
        value: usize = 0,
        fn changed(data: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.value += 1;
        }
        fn wait(self: *@This(), io: std.Io, above: usize, seconds: i64) !void {
            const deadline = @import("desktop-util.zig").monotonicTime(io) + seconds * std.time.us_per_s;
            while (self.value <= above) {
                if (@import("desktop-util.zig").monotonicTime(io) > deadline) return error.Timeout;
                _ = mainloop.iteration(io, false);
                std.Thread.yield() catch {};
            }
        }
    };
    var count: Count = .{};
    const watcher = try Watcher.create(a, std.testing.io, &Count.changed, &count);
    defer watcher.destroy();
    const base = try std.fmt.allocPrintSentinel(a, "{s}/desktop-watch-test-{d}", .{ paths.runtimeDir(), linux.getpid() }, 0);
    defer a.free(base);
    const missing = try std.fmt.allocPrintSentinel(a, "{s}/later", .{base}, 0);
    defer a.free(missing);
    try paths.makeDirectories(base, 0o700);
    try watcher.watch(base);
    try watcher.watch(missing);
    const file = try std.fmt.allocPrintSentinel(a, "{s}/file", .{base}, 0);
    defer a.free(file);
    const created = linux.openat(linux.AT.FDCWD, file, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o600);
    _ = linux.close(@intCast(created));
    try count.wait(std.testing.io, 0, 2);
    const before = count.value;
    try paths.makeDirectories(missing, 0o700);
    try count.wait(std.testing.io, before, 6);
    _ = linux.unlinkat(linux.AT.FDCWD, file, 0);
    _ = linux.unlinkat(linux.AT.FDCWD, missing, linux.AT.REMOVEDIR);
    _ = linux.unlinkat(linux.AT.FDCWD, base, linux.AT.REMOVEDIR);
}
