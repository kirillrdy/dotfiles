//! Native Zig display manager daemon (`desktop-zig dm`).
//! Owns the login VT, runs the unprivileged GDM-styled greeter inside a logind
//! greeter session, authenticates users via PAM (unlocking desktop-secrets),
//! and runs the user's `desktop-zig.service` under `systemd --user`.
const std = @import("std");
const posix = @import("posix");
const dbus = @import("dbus");
const greeter = @import("desktop-greeter.zig");
const pam_auth = @import("desktop-lock-auth.zig");

const PamHandle = ?*posix.pam_handle_t;
extern "c" fn ioctl(c_int, c_ulong, ...) c_int;
extern "c" fn clearenv() c_int;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn chdir([*:0]const u8) c_int;
extern "c" fn kill(posix.pid_t, c_int) c_int;
extern "c" fn nanosleep(*const posix.struct_timespec, ?*posix.struct_timespec) c_int;
extern "c" fn signal(c_int, ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;

const TIOCSCTTY: c_ulong = 0x540E;
const VT_ACTIVATE: c_ulong = 0x5606;
const VT_WAITACTIVE: c_ulong = 0x5607;
const SIGTERM: c_int = 15;
const SIGINT: c_int = 2;
const SIGHUP: c_int = 1;
const SIGPIPE: c_int = 13;

var dm_running: std.atomic.Value(bool) = .init(true);
var active_child: std.atomic.Value(posix.pid_t) = .init(0);

fn handleSignal(_: c_int) callconv(.c) void {
    dm_running.store(false, .release);
    const pid = active_child.load(.acquire);
    if (pid > 0) _ = kill(pid, SIGTERM);
}

fn nullConverse(count: c_int, _: [*c]const [*c]const posix.struct_pam_message, responses: [*c][*c]posix.struct_pam_response, _: ?*anyopaque) callconv(.c) c_int {
    if (count <= 0 or count > 32 or responses == null) return posix.PAM_CONV_ERR;
    const result = posix.calloc(@intCast(count), @sizeOf(posix.struct_pam_response)) orelse return posix.PAM_BUF_ERR;
    responses.* = @ptrCast(@alignCast(result));
    return posix.PAM_SUCCESS;
}

fn sleepMs(ms: u64) void {
    const req: posix.struct_timespec = .{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = nanosleep(&req, null);
}

fn activateVt(vt: c_int) void {
    const fd = posix.open("/dev/tty0", posix.O_RDWR | posix.O_CLOEXEC);
    if (fd < 0) return;
    defer _ = posix.close(fd);
    _ = ioctl(fd, VT_ACTIVATE, vt);
    _ = ioctl(fd, VT_WAITACTIVE, vt);
}

fn attachControllingTty(tty_path: [*:0]const u8) void {
    _ = posix.setsid();
    const fd = posix.open(tty_path, posix.O_RDWR);
    if (fd >= 0) {
        _ = ioctl(fd, TIOCSCTTY, @as(c_int, 0));
        _ = posix.dup2(fd, 0);
        if (fd > 2) _ = posix.close(fd);
    }
}

fn closePamSession(handle: PamHandle) void {
    if (handle == null) return;
    _ = posix.pam_close_session(handle, 0);
    _ = posix.pam_setcred(handle, posix.PAM_DELETE_CRED);
    _ = posix.pam_end(handle, posix.PAM_SUCCESS);
}

fn openPamSession(handle: PamHandle, tty_path: [*:0]const u8, class: []const u8, vt_str: []const u8) bool {
    _ = posix.pam_set_item(handle, posix.PAM_TTY, tty_path);
    var buf: [128:0]u8 = undefined;
    const entries = [_]struct { key: []const u8, val: []const u8 }{
        .{ .key = "XDG_SESSION_TYPE", .val = "wayland" },
        .{ .key = "XDG_SESSION_CLASS", .val = class },
        .{ .key = "XDG_SEAT", .val = "seat0" },
        .{ .key = "XDG_VTNR", .val = vt_str },
        .{ .key = "XDG_SESSION_DESKTOP", .val = "desktop" },
        .{ .key = "XDG_CURRENT_DESKTOP", .val = "desktop:wlroots" },
    };
    for (entries) |e| {
        const kv = std.fmt.bufPrintSentinel(&buf, "{s}={s}", .{ e.key, e.val }, 0) catch continue;
        _ = posix.pam_putenv(handle, kv.ptr);
    }
    if (posix.pam_setcred(handle, posix.PAM_ESTABLISH_CRED) != posix.PAM_SUCCESS) return false;
    if (posix.pam_open_session(handle, 0) != posix.PAM_SUCCESS) {
        _ = posix.pam_setcred(handle, posix.PAM_DELETE_CRED);
        return false;
    }
    return true;
}

fn performPower(a: std.mem.Allocator, action_byte: u8) bool {
    const member: []const u8 = switch (action_byte) {
        0 => "Suspend",
        1 => "Reboot",
        2 => "PowerOff",
        else => return false,
    };
    const conn = dbus.Connection.open(a, .system) catch return false;
    defer conn.close();
    const reply = conn.callBlocking(.{
        .destination = "org.freedesktop.login1",
        .path = "/org/freedesktop/login1",
        .interface = "org.freedesktop.login1.Manager",
        .member = member,
    }, .{true}, 10000) catch return false;
    reply.deinit();
    return true;
}

const AuthResult = struct {
    handle: PamHandle,
    username: [256:0]u8 = @splat(0),
    username_len: usize = 0,
};

fn waitPid(pid: posix.pid_t) void {
    var status: c_int = 0;
    while (posix.waitpid(pid, &status, 0) < 0) {
        if (posix.__errno_location().* != posix.EINTR) break;
    }
}

fn waitChild(pid: posix.pid_t) void {
    active_child.store(pid, .release);
    defer active_child.store(0, .release);
    waitPid(pid);
}

fn copyZ(comptime N: usize, value: ?[*:0]const u8) [N:0]u8 {
    var out: [N:0]u8 = @splat(0);
    if (value) |v| {
        const s = std.mem.span(v);
        const n = @min(s.len, out.len);
        @memcpy(out[0..n], s[0..n]);
    }
    return out;
}

fn runGreeterRound(a: std.mem.Allocator, tty_path: [*:0]const u8, vt_str: []const u8, wlr_renderer: ?[*:0]const u8) ?AuthResult {
    const greeter_pw = posix.getpwnam("greeter") orelse {
        std.log.err("dm: user 'greeter' does not exist", .{});
        return null;
    };
    const greeter_uid = greeter_pw.*.pw_uid;
    const greeter_gid = greeter_pw.*.pw_gid;
    const greeter_home: [*:0]const u8 = if (greeter_pw.*.pw_dir != null) greeter_pw.*.pw_dir else "/var/lib/greeter";

    var fds: [2]c_int = undefined;
    if (posix.socketpair(posix.AF_UNIX, posix.SOCK_STREAM, 0, &fds) != 0) return null;

    // Fork a dedicated session leader so pam_systemd never moves the DM daemon
    // itself into the greeter's logind session scope.
    const session_pid = posix.fork();
    if (session_pid < 0) {
        _ = posix.close(fds[0]);
        _ = posix.close(fds[1]);
        return null;
    }
    if (session_pid == 0) {
        _ = posix.close(fds[0]);
        attachControllingTty(tty_path);

        var conv: posix.struct_pam_conv = .{ .conv = &nullConverse, .appdata_ptr = null };
        var greeter_pam: PamHandle = null;
        if (posix.pam_start("desktop-greeter", "greeter", &conv, &greeter_pam) != posix.PAM_SUCCESS) {
            std.log.err("dm: pam_start(desktop-greeter) failed", .{});
            posix._exit(1);
        }
        if (!openPamSession(greeter_pam, tty_path, "greeter", vt_str)) {
            std.log.err("dm: pam_open_session(desktop-greeter) failed", .{});
            _ = posix.pam_end(greeter_pam, posix.PAM_SYSTEM_ERR);
            posix._exit(1);
        }

        const child_pid = posix.fork();
        if (child_pid < 0) {
            closePamSession(greeter_pam);
            posix._exit(1);
        }
        if (child_pid == 0) {
            const target_fd: c_int = 3;
            if (fds[1] != target_fd) {
                if (posix.dup2(fds[1], target_fd) < 0) posix._exit(1);
                _ = posix.close(fds[1]);
            }
            _ = posix.fcntl(target_fd, posix.F_SETFD, @as(c_int, 0));
            _ = posix.close_range(4, std.math.maxInt(c_uint), 0);

            const runtime_dir_val = posix.pam_getenv(greeter_pam, "XDG_RUNTIME_DIR");
            const session_id_val = posix.pam_getenv(greeter_pam, "XDG_SESSION_ID");
            var runtime_buf: [64:0]u8 = undefined;
            const runtime_fallback = std.fmt.bufPrintSentinel(&runtime_buf, "/run/user/{d}", .{greeter_uid}, 0) catch "/tmp";

            const saved_runtime = copyZ(128, runtime_dir_val orelse runtime_fallback.ptr);
            const saved_sid = copyZ(128, session_id_val);
            const saved_home = copyZ(256, greeter_home);
            const saved_wlr = copyZ(64, wlr_renderer);

            _ = clearenv();
            _ = setenv("HOME", &saved_home, 1);
            _ = setenv("USER", "greeter", 1);
            _ = setenv("LOGNAME", "greeter", 1);
            _ = setenv("XDG_RUNTIME_DIR", &saved_runtime, 1);
            if (saved_sid[0] != 0) _ = setenv("XDG_SESSION_ID", &saved_sid, 1);
            _ = setenv("XDG_SEAT", "seat0", 1);
            var vt_z: [16:0]u8 = @splat(0);
            @memcpy(vt_z[0..@min(vt_str.len, vt_z.len)], vt_str[0..@min(vt_str.len, vt_z.len)]);
            _ = setenv("XDG_VTNR", &vt_z, 1);
            _ = setenv("XDG_SESSION_TYPE", "wayland", 1);
            _ = setenv("XCURSOR_THEME", "Adwaita", 1);
            _ = setenv("XCURSOR_SIZE", "24", 1);
            _ = setenv("DESKTOP_DM_FD", "3", 1);
            if (saved_wlr[0] != 0) _ = setenv("WLR_RENDERER", &saved_wlr, 1);

            if (posix.initgroups("greeter", greeter_gid) != 0) posix._exit(1);
            if (posix.setgid(greeter_gid) != 0) posix._exit(1);
            if (posix.setuid(greeter_uid) != 0) posix._exit(1);
            _ = chdir(&saved_home);

            const argv = [_:null]?[*:0]const u8{ "/proc/self/exe", "greeter" };
            _ = posix.execv("/proc/self/exe", @ptrCast(&argv));
            posix._exit(127);
        }

        _ = posix.close(fds[1]);
        waitPid(child_pid);
        closePamSession(greeter_pam);
        posix._exit(0);
    }

    _ = posix.close(fds[1]);
    var auth_result: ?AuthResult = null;
    while (dm_running.load(.acquire)) {
        var op_byte: [1]u8 = undefined;
        if (!greeter.readAll(fds[0], &op_byte)) break;
        if (op_byte[0] == @backingInt(greeter.Op.power)) {
            var action_byte: [1]u8 = undefined;
            if (!greeter.readAll(fds[0], &action_byte)) break;
            const ok = performPower(a, action_byte[0]);
            const reply = [1]u8{if (ok) @backingInt(greeter.Reply.ok) else @backingInt(greeter.Reply.failed)};
            _ = greeter.writeAll(fds[0], &reply);
        } else if (op_byte[0] == @backingInt(greeter.Op.auth)) {
            var lengths: [4]u8 = undefined;
            if (!greeter.readAll(fds[0], &lengths)) break;
            const user_len = std.mem.readInt(u16, lengths[0..2], .little);
            const pass_len = std.mem.readInt(u16, lengths[2..4], .little);
            if (user_len == 0 or user_len > 256 or pass_len == 0 or pass_len > 1024) {
                const reply = [1]u8{@backingInt(greeter.Reply.failed)};
                _ = greeter.writeAll(fds[0], &reply);
                break;
            }
            var user_buf: [256:0]u8 = @splat(0);
            var pass_buf: [1024:0]u8 = @splat(0);
            defer std.crypto.secureZero(u8, &pass_buf);
            if (!greeter.readAll(fds[0], user_buf[0..user_len]) or !greeter.readAll(fds[0], pass_buf[0..pass_len])) break;
            user_buf[user_len] = 0;
            pass_buf[pass_len] = 0;

            var attempt: pam_auth.Attempt = .{ .user = &user_buf, .password = &pass_buf };
            var user_conv: posix.struct_pam_conv = .{ .conv = &pam_auth.converse, .appdata_ptr = &attempt };
            var user_pam: PamHandle = null;
            var status = posix.pam_start("desktop-login", &user_buf, &user_conv, &user_pam);
            if (status == posix.PAM_SUCCESS) {
                status = posix.pam_authenticate(user_pam, posix.PAM_DISALLOW_NULL_AUTHTOK);
            }
            std.crypto.secureZero(u8, &pass_buf);
            if (status == posix.PAM_SUCCESS) {
                status = posix.pam_acct_mgmt(user_pam, 0);
            }
            if (status == posix.PAM_SUCCESS) {
                const reply = [1]u8{@backingInt(greeter.Reply.ok)};
                _ = greeter.writeAll(fds[0], &reply);
                var res: AuthResult = .{ .handle = user_pam, .username_len = user_len };
                @memcpy(res.username[0..user_len], user_buf[0..user_len]);
                auth_result = res;
                break;
            } else {
                if (user_pam != null) _ = posix.pam_end(user_pam, status);
                const reply = [1]u8{@backingInt(greeter.Reply.failed)};
                if (!greeter.writeAll(fds[0], &reply)) break;
            }
        } else break;
    }
    _ = posix.close(fds[0]);
    // Wait for the greeter session leader (and compositor) to exit and close its logind session.
    waitChild(session_pid);
    return auth_result;
}

fn runUserSession(auth: AuthResult, tty_path: [*:0]const u8, vt_str: []const u8, wlr_renderer: ?[*:0]const u8) void {
    const username: [*:0]const u8 = &auth.username;
    const pw = posix.getpwnam(username) orelse {
        _ = posix.pam_end(auth.handle, posix.PAM_USER_UNKNOWN);
        return;
    };
    const uid = pw.*.pw_uid;
    const gid = pw.*.pw_gid;
    const home: [*:0]const u8 = if (pw.*.pw_dir != null) pw.*.pw_dir else "/";
    const shell: [*:0]const u8 = if (pw.*.pw_shell != null) pw.*.pw_shell else "/bin/sh";

    // Fork a dedicated user session leader so pam_systemd puts it (not the DM
    // daemon) in the user's session-N.scope and starts user@<uid>.service.
    const session_pid = posix.fork();
    if (session_pid < 0) {
        _ = posix.pam_end(auth.handle, posix.PAM_SYSTEM_ERR);
        return;
    }
    if (session_pid == 0) {
        attachControllingTty(tty_path);
        if (!openPamSession(auth.handle, tty_path, "user", vt_str)) {
            std.log.err("dm: pam_open_session(desktop-login) failed for {s}", .{auth.username[0..auth.username_len]});
            _ = posix.pam_end(auth.handle, posix.PAM_SESSION_ERR);
            posix._exit(1);
        }

        const child_pid = posix.fork();
        if (child_pid < 0) {
            closePamSession(auth.handle);
            posix._exit(1);
        }
        if (child_pid == 0) {
            _ = posix.close_range(3, std.math.maxInt(c_uint), 0);

            const saved_home = copyZ(256, home);
            const saved_shell = copyZ(256, shell);
            const saved_wlr = copyZ(64, wlr_renderer);

            const pam_env = posix.pam_getenvlist(auth.handle);
            _ = clearenv();
            if (pam_env) |list| {
                var i: usize = 0;
                while (list[i] != null) : (i += 1) {
                    const entry = std.mem.span(list[i]);
                    if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
                        var key_buf: [256:0]u8 = undefined;
                        if (eq < key_buf.len) {
                            @memcpy(key_buf[0..eq], entry[0..eq]);
                            key_buf[eq] = 0;
                            _ = setenv(key_buf[0..eq :0].ptr, list[i] + eq + 1, 1);
                        }
                    }
                    posix.free(list[i]);
                }
                posix.free(@ptrCast(list));
            }

            _ = setenv("HOME", &saved_home, 1);
            _ = setenv("USER", username, 1);
            _ = setenv("LOGNAME", username, 1);
            _ = setenv("SHELL", &saved_shell, 1);
            var runtime_buf: [64:0]u8 = undefined;
            const runtime_dir = std.fmt.bufPrintSentinel(&runtime_buf, "/run/user/{d}", .{uid}, 0) catch "/tmp";
            _ = setenv("XDG_RUNTIME_DIR", runtime_dir.ptr, 0);
            var bus_buf: [96:0]u8 = undefined;
            const bus_addr = std.fmt.bufPrintSentinel(&bus_buf, "unix:path=/run/user/{d}/bus", .{uid}, 0) catch "";
            if (bus_addr.len > 0) _ = setenv("DBUS_SESSION_BUS_ADDRESS", bus_addr.ptr, 0);
            _ = setenv("PATH", "/run/wrappers/bin:/run/current-system/sw/bin", 0);
            if (saved_wlr[0] != 0) _ = setenv("WLR_RENDERER", &saved_wlr, 1);

            if (posix.initgroups(username, gid) != 0) posix._exit(1);
            if (posix.setgid(gid) != 0) posix._exit(1);
            if (posix.setuid(uid) != 0) posix._exit(1);
            _ = chdir(&saved_home);

            // Source login profile so NixOS environment.variables & sessionVariables
            // are imported into systemd --user before starting desktop-zig.service.
            const script =
                \\set -e
                \\[ -r /etc/profile ] && . /etc/profile
                \\for v in XDG_SESSION_ID XDG_SEAT XDG_VTNR XDG_SESSION_TYPE XDG_SESSION_DESKTOP XDG_CURRENT_DESKTOP WLR_RENDERER GI_TYPELIB_PATH GDK_PIXBUF_MODULE_FILE EDITOR NEOVIDE_FORK; do
                \\  eval "val=\${$v:-}"
                \\  if [ -n "$val" ]; then systemctl --user import-environment "$v"; fi
                \\done
                \\trap 'systemctl --user stop desktop-zig.service 2>/dev/null || true' TERM INT HUP
                \\systemctl --user start --wait desktop-zig.service
            ;
            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", script };
            _ = posix.execv("/bin/sh", @ptrCast(&argv));
            posix._exit(127);
        }

        waitPid(child_pid);
        closePamSession(auth.handle);
        posix._exit(0);
    }

    // The child owns and closes the PAM session; end only the parent's copy of the handle.
    _ = posix.pam_end(auth.handle, posix.PAM_SUCCESS);
    waitChild(session_pid);
}

pub fn run(a: std.mem.Allocator) !void {
    _ = signal(SIGPIPE, @ptrFromInt(1));
    _ = signal(SIGTERM, &handleSignal);
    _ = signal(SIGINT, &handleSignal);
    _ = signal(SIGHUP, &handleSignal);

    const vt_str = if (posix.getenv("DESKTOP_DM_VT")) |v| std.mem.span(v) else "1";
    const vt_num = std.fmt.parseInt(c_int, vt_str, 10) catch 1;
    var tty_buf: [32:0]u8 = undefined;
    const tty_path = try std.fmt.bufPrintSentinel(&tty_buf, "/dev/tty{d}", .{vt_num}, 0);
    const wlr_renderer = posix.getenv("WLR_RENDERER");

    while (dm_running.load(.acquire)) {
        activateVt(vt_num);
        if (runGreeterRound(a, tty_path.ptr, vt_str, wlr_renderer)) |auth| {
            runUserSession(auth, tty_path.ptr, vt_str, wlr_renderer);
        } else if (dm_running.load(.acquire)) {
            sleepMs(500);
        }
    }
}
