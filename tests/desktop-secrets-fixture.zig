const std = @import("std");
const desktop = @import("desktop");
const secrets = desktop.secrets;
const keyboard = @import("desktop").keyboard;
const mainloop = @import("desktop").mainloop;
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
    while (dialog.response_idle != 0) _ = mainloop.iteration(true);
    try cleared(dialog);
    try std.testing.expect(dialog.view.status_error);
    try std.testing.expectEqual(@import("desktop").askpass.native.Target.entry, dialog.view.focus);
    try dialog.entry.?.insert("integration-vault-password");
    if (dialog.confirmation) |entry| try entry.insert("integration-vault-password");
    // The successful response is delivered after this callback returns.
    _ = dialog.handleKey(0xff0d, 0);
}
fn checkDialogs(allocator: std.mem.Allocator) !void {
    const dialog = try secrets.createImportDialog(allocator);
    defer dialog.destroy();
    try dialog.entry.?.insert("private-surrounding-text");
    dialog.focus(.entry);
    const surface = dialog.window.surface.?;
    const surrounding = surface.input.surrounding.?(surface.data, surface).?;
    try std.testing.expect(surrounding.private);
    try std.testing.expectEqualStrings("", surrounding.text);
    try std.testing.expectEqual(@as(u32, 0), surrounding.cursor);
    dialog.entry.?.echo = true;
    try std.testing.expect(surface.input.surrounding.?(surface.data, surface).?.private);
    dialog.entry.?.echo = false;
    dialog.clear();
    dialog.window.setSize(560, dialog.view.height);
    for (0..100) |_| {
        while (mainloop.iteration(false)) {}
        mainloop.sleep(1000);
    }
    try std.testing.expectEqual(dialog.window.surface.?.width, dialog.view.width);
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
    try std.testing.expect(dialog.handleKey('a', keyboard.control));
    try dialog.confirmation.?.insert("replacement");
    try std.testing.expectEqualStrings("test-東京🔑", dialog.entry.?.buffer.value());
    try std.testing.expect(dialog.handleKey(0xfe20, keyboard.shift));
    try std.testing.expect(dialog.entry.?.focused and !dialog.confirmation.?.focused);
    try std.testing.expect(dialog.handleKey(0xff1b, 0));
    try cleared(dialog);
    std.debug.print("Secret Service dialogs: creation/import confirmation, focus, Unicode edits, mismatch and cancellation clearing passed\n", .{});
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "dialogs")) return checkDialogs(init.gpa);
    if (args.len == 3 and std.mem.eql(u8, args[1], "import")) {
        return secrets.importAt(init.io, try arena.allocator().dupeSentinel(u8, args[2], 0), "integration-vault-password");
    }
    if (args.len != 2) return error.ExpectedDirectory;
    const mode = std.c.getenv("DESKTOP_SECRETS_FIXTURE_PROMPTS");
    try secrets.runAtWithOptions(init.gpa, init.io, try arena.allocator().dupeSentinel(u8, args[1], 0), .{
        .prompt_ready = if (mode != null and std.mem.eql(u8, std.mem.span(mode.?), "accept")) &ready else null,
    });
}
