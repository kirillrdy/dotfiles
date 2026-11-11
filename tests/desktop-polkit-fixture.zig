//! Native PolicyKit dialog checks with synthetic credentials on Wayland.
const std = @import("std");
const polkit = @import("desktop").polkit;
const c = polkit.c;
const cast = c.__zig.cast;

const Reply = struct {
    count: usize = 0,
    id: c_int = 0,
    fn response(data: ?*anyopaque, accepted: bool) void {
        const self = cast(Reply, data);
        self.count += 1;
        self.id = if (accepted) c.GTK_RESPONSE_OK else c.GTK_RESPONSE_CANCEL;
    }
};
fn checkDialog() !void {
    var dialog = try polkit.Dialog.create("org.dotfiles.test<&>", "Authentication is required: 東京", "test<&>", null);
    defer dialog.destroy();
    var reply: Reply = .{};
    dialog.native.responded = &Reply.response;
    dialog.native.response_context = &reply;
    try std.testing.expect(std.mem.indexOf(u8, dialog.native.prompt, "Action: org.dotfiles.test<&>") != null);
    try std.testing.expect(std.mem.indexOf(u8, dialog.native.prompt, "Password: (test<&>)") != null);
    try std.testing.expectEqualStrings("Authentication Required", dialog.native.view.title);
    try std.testing.expectEqualStrings("Authenticate", dialog.native.view.accept_label.?);
    // Return cannot submit before the helper asks for a response.
    try std.testing.expect(dialog.native.handleKey(0xff0d, 0));
    try std.testing.expectEqual(@as(usize, 0), reply.count);
    try dialog.setPrompt("Password: 東京 <&>", false);
    try std.testing.expect(!dialog.native.entry.?.echo);
    try dialog.native.entry.?.insert("synthetic-secret");
    try std.testing.expectEqualStrings("synthetic-secret", dialog.answer());
    try dialog.setError("Incorrect <&> password — try again");
    try std.testing.expect(dialog.native.view.status_error);
    try std.testing.expectEqualStrings("Incorrect <&> password — try again", dialog.native.view.status.?);
    // Status and buttons remain below the entry at both scale factors.
    for ([_]u32{ 1, 2 }) |scale| {
        try dialog.native.view.prepare(std.heap.page_allocator, dialog.native.prompt, scale);
        try std.testing.expect(dialog.native.view.buttonRect(.accept).y >= dialog.native.view.entryRect().y + 62 + @as(f64, @floatFromInt(dialog.native.view.status_height)));
    }
    // A new MFA challenge erases the previous response and can request echo.
    try dialog.setPrompt("Token:", true);
    try std.testing.expect(dialog.native.entry.?.echo);
    try std.testing.expectEqualStrings("", dialog.answer());
    for (dialog.native.entry.?.buffer.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try dialog.native.entry.?.insert("123456");
    try std.testing.expect(dialog.native.handleKey(0xff0d, 0));
    while (reply.count < 1) _ = c.g_main_context_iteration(null, 1);
    try std.testing.expectEqual(c.GTK_RESPONSE_OK, reply.id);
    dialog.clear();
    dialog.setEnabled(false);
    try std.testing.expect(dialog.native.handleKey('x', 0));
    try std.testing.expectEqualStrings("", dialog.answer());
    try std.testing.expect(dialog.native.handleKey(0xff1b, 0));
    while (reply.count < 2) _ = c.g_main_context_iteration(null, 1);
    try std.testing.expectEqual(c.GTK_RESPONSE_CANCEL, reply.id);
    try std.testing.expectEqual(@as(usize, 2), reply.count);
}
pub fn main(init: std.process.Init) !void {
    _ = init;
    c.gtk_init(null, null);
    try checkDialog();
    std.debug.print("desktop-polkit: native labels, locked entry, helper wait, status, MFA clearing and cancellation passed\n", .{});
}
