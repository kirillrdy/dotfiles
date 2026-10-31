//! Real PAM dispatcher with an isolated login substack and a fixed dummy token.
const std = @import("std");
const desktop = @import("desktop");
const libc = desktop.libc;
const pam = desktop.pam;
fn converse(_: c_int, _: [*c]const [*c]const pam.pam_message, _: [*c][*c]pam.pam_response, _: ?*anyopaque) callconv(.c) c_int {
    return pam.PAM_CONV_ERR;
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.ExpectedPrivatePolicy;
    const conversation = pam.pam_conv{ .conv = &converse, .appdata_ptr = null };
    var handle: ?*pam.pam_handle_t = null;
    const user = libc.getpwuid(libc.getuid()) orelse return error.NoUser;
    try std.testing.expectEqual(@as(c_int, 0), pam.pam_start_confdir("greetd-test", user.*.pw_name, &conversation, (try a.dupeSentinel(u8, args[1], 0)).ptr, &handle));
    defer _ = pam.pam_end(handle, 0);
    const authenticated = pam.pam_authenticate(handle, 0);
    std.debug.print("private PAM authentication: {d}\n", .{authenticated});
    try std.testing.expectEqual(@as(c_int, 0), authenticated);
    const opened = pam.pam_open_session(handle, 0);
    std.debug.print("private PAM session: {d}\n", .{opened});
    try std.testing.expectEqual(@as(c_int, 0), opened);
    try std.testing.expectEqual(@as(c_int, 0), pam.pam_close_session(handle, 0));
}
