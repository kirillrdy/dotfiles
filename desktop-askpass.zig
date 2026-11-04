//! OpenSSH askpass protocol with native pixels and a locked, masked text entry.
const std = @import("std");
pub const c = @import("desktop-gtk.zig");
const libc = @import("desktop-libc.zig");
pub const native = @import("desktop-askpass-view.zig");
pub const password = @import("desktop-password-entry.zig");
pub const Mode = native.Mode;
pub const Dialog = @import("desktop-auth-dialog.zig").Dialog;

pub fn main(init: std.process.Init) void {
    const status = run(init) catch 1;
    if (status != 0) std.process.exit(status);
}
fn run(init: std.process.Init) !u8 {
    var arguments = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arguments.deinit();
    return runArgs(init, try init.minimal.args.toSlice(arguments.allocator()));
}
pub fn runArgs(init: std.process.Init, args: []const []const u8) !u8 {
    // Passwords should not appear in a core dump or another process's ptrace
    // view. No password is copied into argv, an environment variable or a file.
    if (libc.prctl(libc.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return 1;
    if (c.gtk_init_check(null, null) == 0) return 1;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const text = try arena.allocator().dupeSentinel(u8, if (args.len > 1) args[1] else "Enter your SSH passphrase:", 0);
    const hint = c.g_getenv("SSH_ASKPASS_PROMPT");
    const dialog = try Dialog.create(Mode.fromHint(if (hint) |h| std.mem.span(h) else null), text);
    defer dialog.destroy();
    dialog.run();
    return dialog.writeAnswer(init.io, std.Io.File.stdout());
}
