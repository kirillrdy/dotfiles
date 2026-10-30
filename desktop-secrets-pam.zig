//! Optional PAM login bridge. Cache the existing token; never prompt or authenticate.
//! Only a child with the user's UID connects to their session bus.
const std = @import("std");
const c = @import("pam-posix");
const Handle = opaque {};
extern fn pam_get_item(?*Handle, c_int, *?*const anyopaque) c_int;
extern fn pam_get_user(?*Handle, *?[*:0]const u8, ?[*:0]const u8) c_int;
extern fn pam_getenv(?*Handle, [*:0]const u8) ?[*:0]const u8;
extern fn pam_set_data(?*Handle, [*:0]const u8, ?*anyopaque, *const fn (?*Handle, ?*anyopaque, c_int) callconv(.c) void) c_int;
extern fn pam_get_data(?*const Handle, [*:0]const u8, *?*const anyopaque) c_int;
const Cached = struct { length: usize, password: [4096]u8 };
fn cleanup(_: ?*Handle, data: ?*anyopaque, _: c_int) callconv(.c) void {
    if (data) |ptr| {
        const cache: *Cached = @ptrCast(@alignCast(ptr));
        std.crypto.secureZero(u8, std.mem.asBytes(cache));
        _ = c.munlock(cache, @sizeOf(Cached));
        std.heap.page_allocator.destroy(cache);
    }
}
export fn pam_sm_authenticate(handle: ?*Handle, _: c_int, _: c_int, _: [*c][*c]const u8) c_int {
    var token: ?*const anyopaque = null;
    if (pam_get_item(handle, 6, &token) != 0 or token == null) return 25; // PAM_IGNORE; PAM_AUTHTOK
    const password = std.mem.span(@as([*:0]const u8, @ptrCast(token.?)));
    if (password.len == 0 or password.len > 4096) return 25;
    const cached = std.heap.page_allocator.create(Cached) catch return 25;
    cached.* = .{ .length = password.len, .password = @splat(0) };
    @memcpy(cached.password[0..password.len], password);
    if (c.mlock(cached, @sizeOf(Cached)) != 0) {
        cleanup(handle, cached, 0);
        return 25;
    }
    if (pam_set_data(handle, "desktop-secrets-token", cached, &cleanup) != 0) cleanup(handle, cached, 0);
    return 25;
}
export fn pam_sm_setcred(_: ?*Handle, _: c_int, _: c_int, _: [*c][*c]const u8) c_int {
    return 25;
}
export fn pam_sm_close_session(_: ?*Handle, _: c_int, _: c_int, _: [*c][*c]const u8) c_int {
    return 25;
}
export fn pam_sm_open_session(handle: ?*Handle, _: c_int, argc: c_int, argv: [*c][*c]const u8) c_int {
    var raw: ?*const anyopaque = null;
    if (pam_get_data(handle, "desktop-secrets-token", &raw) != 0 or raw == null) return 25;
    const cached: *Cached = @ptrCast(@alignCast(@constCast(raw.?)));
    if (cached.length == 0) return 25;
    defer {
        std.crypto.secureZero(u8, &cached.password);
        cached.length = 0;
    }
    var username: ?[*:0]const u8 = null;
    if (pam_get_user(handle, &username, null) != 0 or username == null) return 25;
    const user = c.getpwnam(username.?) orelse return 25;
    const user_id = user.*.pw_uid;
    const group_id = user.*.pw_gid;
    if (user.*.pw_uid == 0) return 25;
    var helper: ?[*:0]const u8 = null;
    for (0..@intCast(@max(argc, 0))) |i| {
        const option = std.mem.span(argv[i]);
        if (std.mem.startsWith(u8, option, "helper=/")) helper = @ptrCast(argv[i] + 7);
    }
    const executable = helper orelse return 25;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = std.fmt.allocPrintSentinel(a, "HOME={s}", .{user.*.pw_dir}, 0) catch return 25;
    const runtime = std.fmt.allocPrintSentinel(a, "XDG_RUNTIME_DIR=/run/user/{d}", .{user.*.pw_uid}, 0) catch return 25;
    const bus = std.fmt.allocPrintSentinel(a, "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{d}/bus", .{user.*.pw_uid}, 0) catch return 25;
    const session = std.fmt.allocPrintSentinel(a, "XDG_SESSION_ID={s}", .{pam_getenv(handle, "XDG_SESSION_ID") orelse ""}, 0) catch return 25;
    const env = [_:null]?[*:0]const u8{ home, runtime, bus, session };
    const args = [_:null]?[*:0]const u8{ executable, "secrets-login" };
    var fds: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &fds) != 0) return 25;
    const child = c.fork();
    if (child == 0) {
        _ = c.close(fds[1]);
        if (c.dup2(fds[0], 0) < 0 or c.fcntl(0, c.F_SETFD, @as(c_int, 0)) < 0) c._exit(1);
        if (fds[0] != 0) _ = c.close(fds[0]);
        const nullfd = c.open("/dev/null", c.O_RDWR);
        if (nullfd < 0 or c.dup2(nullfd, 1) < 0 or c.dup2(nullfd, 2) < 0) c._exit(1);
        if (nullfd > 2) _ = c.close(nullfd);
        if (c.close_range(3, std.math.maxInt(c_uint), 0) != 0) c._exit(1);
        if (c.geteuid() == 0) {
            if (c.initgroups(username.?, group_id) != 0 or c.setgid(group_id) != 0 or c.setuid(user_id) != 0) c._exit(1);
        } else if (c.geteuid() != user_id or c.getegid() != group_id) c._exit(1);
        _ = c.execve(executable, @ptrCast(&args), @ptrCast(&env));
        c._exit(1);
    }
    _ = c.close(fds[0]);
    if (child > 0) {
        // The socketpair suppresses SIGPIPE if the helper exits before reading.
        var offset: usize = 0;
        while (offset < cached.length) {
            const n = c.send(fds[1], cached.password[offset..].ptr, cached.length - offset, c.MSG_NOSIGNAL);
            if (n < 0 and c.__errno_location().* == c.EINTR) continue;
            if (n <= 0) break;
            offset += @intCast(n);
        }
    }
    _ = c.close(fds[1]);
    if (child > 0) {
        var status: c_int = 0;
        while (c.waitpid(child, &status, 0) < 0 and c.__errno_location().* == c.EINTR) {}
    }
    return 25;
}
