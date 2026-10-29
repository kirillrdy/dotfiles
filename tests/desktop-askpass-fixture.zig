//! Askpass protocol tests. Uses only synthetic credentials under Xvfb.
const std = @import("std");
const askpass = @import("askpass");
const c = askpass.c;
const libc = @import("libc");
const assert = std.debug.assert;
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
const Response = struct {
    dialog: *askpass.Dialog,
    response: c_int,
    fn send(data: c.gpointer) callconv(.c) c.gboolean {
        const self: *Response = @ptrCast(@alignCast(data));
        c.gtk_dialog_response(cast(c.GtkDialog, self.dialog.window), self.response);
        return 0;
    }
    fn signal(_: c.gpointer) callconv(.c) c.gboolean {
        _ = libc.raise(libc.SIGTERM);
        return 0;
    }
};
fn check(init: std.process.Init, root: []const u8, mode: askpass.Mode, response: c_int, expected: []const u8, status: u8, signal: bool) !void {
    const prompt = "Enter passphrase for <test-key> at 100%: 東京";
    var dialog = askpass.Dialog.create(mode, prompt);
    defer dialog.destroy();
    try std.testing.expectEqualStrings(prompt, std.mem.span(c.gtk_label_get_text(cast(c.GtkLabel, dialog.prompt))));
    assert(c.gtk_label_get_use_markup(cast(c.GtkLabel, dialog.prompt)) == 0);
    if (dialog.entry) |entry| {
        assert(c.gtk_entry_get_visibility(cast(c.GtkEntry, entry)) == 0);
        assert(c.gtk_entry_get_input_purpose(cast(c.GtkEntry, entry)) == c.GTK_INPUT_PURPOSE_PASSWORD);
        c.gtk_entry_set_text(cast(c.GtkEntry, entry), "test-secret:$()\\ 東京");
    } else assert(mode != .password);
    var reply = Response{ .dialog = &dialog, .response = response };
    _ = c.g_timeout_add(25, if (signal) &Response.signal else &Response.send, &reply);
    dialog.run();
    const path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/answer", .{root});
    defer std.heap.page_allocator.free(path);
    const file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    {
        defer file.close(init.io);
        try std.testing.expectEqual(status, try dialog.writeAnswer(init.io, file));
    }
    const answer = try std.Io.Dir.cwd().readFileAlloc(init.io, path, std.heap.page_allocator, .limited(4096));
    defer std.heap.page_allocator.free(answer);
    try std.testing.expectEqualStrings(expected, answer);
    if (dialog.entry) |entry| try std.testing.expectEqualStrings("", std.mem.span(c.gtk_entry_get_text(cast(c.GtkEntry, entry))));
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    c.gtk_init(null, null);
    const root = c.g_dir_make_tmp("desktop-askpass-XXXXXX", null).?;
    defer c.g_free(root);
    defer std.Io.Dir.cwd().deleteTree(init.io, std.mem.span(root)) catch {};
    try std.testing.expectEqual(askpass.Mode.confirm, askpass.Mode.fromHint("confirm"));
    try std.testing.expectEqual(askpass.Mode.information, askpass.Mode.fromHint("none"));
    try std.testing.expectEqual(askpass.Mode.password, askpass.Mode.fromHint(null));
    try std.testing.expectEqual(askpass.Mode.password, askpass.Mode.fromHint("unknown"));
    try check(init, std.mem.span(root), .password, c.GTK_RESPONSE_OK, "test-secret:$()\\ 東京\n", 0, false);
    try check(init, std.mem.span(root), .password, c.GTK_RESPONSE_CANCEL, "", 1, false);
    try check(init, std.mem.span(root), .password, c.GTK_RESPONSE_DELETE_EVENT, "", 1, false);
    try check(init, std.mem.span(root), .confirm, c.GTK_RESPONSE_OK, "yes\n", 0, false);
    try check(init, std.mem.span(root), .confirm, c.GTK_RESPONSE_CANCEL, "", 1, false);
    try check(init, std.mem.span(root), .information, c.GTK_RESPONSE_OK, "", 0, false);
    try check(init, std.mem.span(root), .password, c.GTK_RESPONSE_CANCEL, "", 1, true);
    if (args.len > 1) {
        var env = try init.minimal.environ.createMap(arena.allocator());
        try env.put("GDK_BACKEND", "wayland");
        try env.put("DISPLAY", "");
        try env.put("WAYLAND_DISPLAY", "");
        const failed = try std.process.run(arena.allocator(), init.io, .{ .argv = &.{ args[1], "askpass", "A prompt that must not reach stdout" }, .environ_map = &env });
        assert(failed.term == .exited and failed.term.exited == 1);
        try std.testing.expectEqualStrings("", failed.stdout);
    }
    std.debug.print("desktop-askpass: masked input, Unicode prompts, stdout protocol, confirmation, information, cancellation, signals and missing display passed\n", .{});
}
