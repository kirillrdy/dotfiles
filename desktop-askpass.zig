//! OpenSSH askpass protocol with native pixels and a locked, masked text entry.
const std = @import("std");
const libc = @import("desktop-libc.zig");
pub const native = @import("desktop-askpass-view.zig");
pub const password = @import("desktop-password-entry.zig");
pub const Mode = native.Mode;
pub const Dialog = @import("desktop-auth-dialog.zig").Dialog;

pub fn runArgs(init: std.process.Init, args: []const []const u8) !u8 {
    // Passwords should not appear in a core dump or another process's ptrace
    // view. No password is copied into argv, an environment variable or a file.
    if (libc.prctl(libc.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return 1;
    const allocator = init.gpa;
    const text = try allocator.dupeSentinel(u8, if (args.len > 1) args[1] else "Enter your SSH passphrase:", 0);
    defer allocator.free(text);
    const hint = std.c.getenv("SSH_ASKPASS_PROMPT");
    const dialog = Dialog.create(allocator, init.io, Mode.fromHint(if (hint) |h| std.mem.span(h) else null), text) catch return 1;
    defer dialog.destroy();
    dialog.run();
    return dialog.writeAnswer(init.io, std.Io.File.stdout());
}
