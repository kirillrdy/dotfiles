const std = @import("std");
const desktop = @import("desktop");
const secrets = desktop.secrets;
const c = desktop.gtk;
fn cleared(dialog: *secrets.Dialog) !void {
    for ([_]?*@import("desktop").askpass.password.Entry{ dialog.entry, dialog.confirmation }) |slot| {
        if (slot) |entry| {
            try std.testing.expectEqualStrings("", entry.buffer.value());
            for (entry.buffer.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }
}
fn ready(dialog: *secrets.Dialog) void {
    checkPrompt(dialog) catch @panic("native Secret Service prompt check failed");
}
fn checkPrompt(dialog: *secrets.Dialog) !void {
    try dialog.entry.?.insert("wrong-password");
    if (dialog.confirmation) |entry| try entry.insert("different-password");
    dialog.respond(true);
    try cleared(dialog);
    try std.testing.expect(dialog.view.status_error);
    try std.testing.expectEqual(@import("desktop").askpass.native.Target.entry, dialog.view.focus);
    try dialog.entry.?.insert("integration-vault-password");
    if (dialog.confirmation) |entry| try entry.insert("integration-vault-password");
    // A successful response destroys the dialog synchronously.
    _ = dialog.handleKey(0xff0d, 0);
}
fn checkDialogs() !void {
    c.gtk_init(null, null);
    const dialog = try secrets.createImportDialog();
    defer dialog.destroy();
    // Host decorations or themes may allocate more than the nominal width.
    c.gtk_widget_set_size_request(dialog.canvas, 560, -1);
    for (0..100) |_| {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        c.g_usleep(1000);
    }
    try std.testing.expectEqual(@as(u32, @intCast(c.gtk_widget_get_allocated_width(dialog.canvas))), dialog.view.width);
    try std.testing.expect(dialog.view.entryRect().width >= 512);
    try std.testing.expectEqualStrings("Import Saved Passwords", dialog.view.title);
    try std.testing.expectEqualStrings("Continue", dialog.view.accept_label.?);
    try std.testing.expect(!try dialog.validatePassword());
    try cleared(dialog);
    try std.testing.expect(dialog.handleKey('a', 0));
    try std.testing.expect(dialog.handleKey(0xff09, 0));
    try std.testing.expect(dialog.confirmation.?.focused and !dialog.entry.?.focused);
    try std.testing.expect(dialog.handleKey('b', 0));
    try std.testing.expect(!try dialog.validatePassword());
    try cleared(dialog);
    try std.testing.expectEqualStrings("Passwords do not match. Please try again.", dialog.view.status.?);
    try dialog.entry.?.insert("test-東京🔑");
    try std.testing.expect(dialog.handleKey(0xff09, 0));
    try dialog.confirmation.?.insert("test-東京🔑");
    try std.testing.expect(try dialog.validatePassword());
    // Editing/select-all in the second field must leave the first intact.
    try std.testing.expect(dialog.handleKey('a', c.GDK_CONTROL_MASK));
    try dialog.confirmation.?.insert("replacement");
    try std.testing.expectEqualStrings("test-東京🔑", dialog.entry.?.buffer.value());
    try std.testing.expect(dialog.handleKey(0xfe20, c.GDK_SHIFT_MASK));
    try std.testing.expect(dialog.entry.?.focused and !dialog.confirmation.?.focused);
    try std.testing.expect(dialog.handleKey(0xff1b, 0));
    try cleared(dialog);
    std.debug.print("Secret Service dialogs: creation/import confirmation, focus, Unicode edits, mismatch and cancellation clearing passed\n", .{});
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "dialogs")) return checkDialogs();
    if (args.len == 3 and std.mem.eql(u8, args[1], "import")) {
        return secrets.importAt(try arena.allocator().dupeSentinel(u8, args[2], 0), "integration-vault-password");
    }
    if (args.len != 2) return error.ExpectedDirectory;
    const mode = c.g_getenv("DESKTOP_SECRETS_FIXTURE_PROMPTS");
    try secrets.runAtWithOptions(try arena.allocator().dupeSentinel(u8, args[1], 0), .{
        .prompt_ready = if (mode != null and std.mem.eql(u8, std.mem.span(mode.?), "accept")) &ready else null,
    });
}
