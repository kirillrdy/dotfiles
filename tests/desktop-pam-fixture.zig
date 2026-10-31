//! Exercise the real PAM dispatcher with private policies, never the host policy.
const std = @import("std");
const pam = if (@hasDecl(@import("root"), "pam")) @import("pam") else @import("../desktop-pam.zig");
const libc = @import("../desktop-libc.zig");
var messages: usize = 0;
fn converse(count: c_int, input: [*c]const [*c]const pam.pam_message, output: [*c][*c]pam.pam_response, _: ?*anyopaque) callconv(.c) c_int {
    output.* = null;
    if (count <= 0 or count > 32) return pam.PAM_CONV_ERR;
    for (0..@intCast(count)) |i| {
        if (input[i].*.msg_style != pam.PAM_TEXT_INFO and input[i].*.msg_style != pam.PAM_ERROR_MSG) return pam.PAM_CONV_ERR;
    }
    // Informational messages still require an allocated, empty response array.
    output.* = @ptrCast(@alignCast(libc.calloc(@intCast(count), @sizeOf(pam.pam_response)) orelse return pam.PAM_BUF_ERR));
    messages += @intCast(count);
    return pam.PAM_SUCCESS;
}
fn check(directory: [:0]const u8, service: [*:0]const u8, auth_expected: ?c_int, account_expected: ?c_int) !void {
    const conversation = pam.pam_conv{ .conv = &converse, .appdata_ptr = null };
    var handle: ?*pam.pam_handle_t = null;
    var status = pam.pam_start_confdir(service, "desktop-zig-nonexistent-fixture-user", &conversation, directory.ptr, &handle);
    try std.testing.expectEqual(@as(c_int, pam.PAM_SUCCESS), status);
    defer std.debug.assert(pam.pam_end(handle, status) == pam.PAM_SUCCESS);
    if (auth_expected) |expected| {
        status = pam.pam_authenticate(handle, pam.PAM_DISALLOW_NULL_AUTHTOK);
        if (expected < 0) try std.testing.expect(status != pam.PAM_SUCCESS) else try std.testing.expectEqual(expected, status);
    }
    if (account_expected) |expected| {
        status = pam.pam_acct_mgmt(handle, 0);
        if (expected < 0) try std.testing.expect(status != pam.PAM_SUCCESS) else try std.testing.expectEqual(expected, status);
    }
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len != 2) return error.ExpectedPrivateConfigurationDirectory;
    const directory = try arena.allocator().dupeSentinel(u8, args[1], 0);
    try check(directory, "system-allow", pam.PAM_SUCCESS, pam.PAM_SUCCESS);
    try std.testing.expect(messages > 0);
    try check(directory, "client-allow", pam.PAM_SUCCESS, pam.PAM_SUCCESS);
    try check(directory, "system-deny", pam.PAM_AUTH_ERR, null);
    try check(directory, "system-expired", pam.PAM_SUCCESS, pam.PAM_ACCT_EXPIRED);
    try check(directory, "module-missing", -1, null);
    try check(directory, "system-unix", null, pam.PAM_USER_UNKNOWN);
    std.debug.print("desktop-pam: system/client modules, conversation, authentication denial, account expiry, unknown user, missing module and cleanup passed\n", .{});
}
