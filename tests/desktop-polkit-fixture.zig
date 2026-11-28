//! Native PolicyKit dialog checks with synthetic credentials on Wayland.
const std = @import("std");
const polkit = @import("desktop").polkit;
const mainloop = @import("desktop").mainloop;
const util = @import("desktop").util;
const cast = util.cast;

const Reply = struct {
    count: usize = 0,
    accepted: bool = false,
    fn response(data: ?*anyopaque, accepted: bool) void {
        const self = cast(Reply, data);
        self.count += 1;
        self.accepted = accepted;
    }
};
fn checkDialog(allocator: std.mem.Allocator, io: std.Io) !void {
    var dialog = try polkit.Dialog.create(allocator, io, "org.dotfiles.test<&>", "Authentication is required: 東京", "test<&>");
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
        // The view frees masks it rendered earlier, so it must get the dialog's own allocator.
        try dialog.native.view.prepare(dialog.native.allocator, dialog.native.prompt, scale);
        try std.testing.expect(dialog.native.view.buttonRect(.accept).y >= dialog.native.view.entryRect().y + 62 + @as(f64, @floatFromInt(dialog.native.view.status_height)));
    }
    // A new MFA challenge erases the previous response and can request echo.
    try dialog.setPrompt("Token:", true);
    try std.testing.expect(dialog.native.entry.?.echo);
    try std.testing.expectEqualStrings("", dialog.answer());
    for (dialog.native.entry.?.buffer.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try dialog.native.entry.?.insert("123456");
    try std.testing.expect(dialog.native.handleKey(0xff0d, 0));
    while (reply.count < 1) _ = mainloop.iteration(io, true);
    try std.testing.expect(reply.accepted);
    dialog.clear();
    dialog.setEnabled(false);
    try std.testing.expect(dialog.native.handleKey('x', 0));
    try std.testing.expectEqualStrings("", dialog.answer());
    try std.testing.expect(dialog.native.handleKey(0xff1b, 0));
    while (reply.count < 2) _ = mainloop.iteration(io, true);
    try std.testing.expect(!reply.accepted);
    try std.testing.expectEqual(@as(usize, 2), reply.count);
}
pub fn main(init: std.process.Init) !void {
    try checkDialog(init.gpa, init.io);
    std.debug.print("desktop-polkit: native labels, locked entry, helper wait, status, MFA clearing and cancellation passed\n", .{});
}
