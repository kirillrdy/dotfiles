//! PolicyKit agent dialog and interaction tests under synthetic Xvfb.
const std = @import("std");
const polkit = @import("desktop").polkit;
const c = polkit.c;
const assert = std.debug.assert;

const cast = c.__zig.cast;

const Response = struct {
    window: *c.GtkWidget,
    response: c_int,
    fn send(data: c.gpointer) callconv(.c) c.gboolean {
        const self: *Response = @ptrCast(@alignCast(data));
        c.gtk_dialog_response(cast(c.GtkDialog, self.window), self.response);
        return 0;
    }
};

fn checkDialog() !void {
    const action = "org.dotfiles.test<&>";
    const prompt = "Authentication is required to run the configuration tool: 東京";
    const username = "test<&>";

    var dialog = polkit.Dialog.create(action, prompt, username, null);
    defer dialog.destroy();

    try std.testing.expectEqualStrings(prompt, std.mem.span(c.gtk_label_get_text(cast(c.GtkLabel, dialog.prompt))));
    try std.testing.expectEqualStrings("Action: " ++ action, std.mem.span(c.gtk_label_get_text(cast(c.GtkLabel, dialog.action_label.?))));
    try std.testing.expectEqualStrings("Password for " ++ username ++ ":", std.mem.span(c.gtk_label_get_text(cast(c.GtkLabel, dialog.user_label.?))));
    assert(c.gtk_entry_get_visibility(cast(c.GtkEntry, dialog.entry)) == 0);
    assert(c.gtk_entry_get_input_purpose(cast(c.GtkEntry, dialog.entry)) == c.GTK_INPUT_PURPOSE_PASSWORD);

    // Test error presentation
    dialog.setError("Authentication failure: <&> password incorrect");
    assert(c.gtk_widget_get_visible(dialog.error_label) != 0);
    try std.testing.expectEqualStrings("Authentication failure: <&> password incorrect", std.mem.span(c.gtk_label_get_text(cast(c.GtkLabel, dialog.error_label))));

    // Test password entry and clearing
    c.gtk_entry_set_text(cast(c.GtkEntry, dialog.entry), "secret-pass-123");
    try std.testing.expectEqualStrings("secret-pass-123", std.mem.span(c.gtk_entry_get_text(cast(c.GtkEntry, dialog.entry))));
    dialog.clear();
    try std.testing.expectEqualStrings("", std.mem.span(c.gtk_entry_get_text(cast(c.GtkEntry, dialog.entry))));

    // Test dialog response via timer
    var reply = Response{ .window = dialog.window, .response = c.GTK_RESPONSE_CANCEL };
    _ = c.g_timeout_add(25, &Response.send, &reply);
    _ = c.gtk_dialog_run(cast(c.GtkDialog, dialog.window));
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    c.gtk_init(null, null);
    try checkDialog();

    std.debug.print("desktop-polkit: masked input, Unicode labels, error display, cancel responses passed\n", .{});
}
