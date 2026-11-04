//! Askpass protocol tests. Uses only synthetic credentials on an isolated display.
const std = @import("std");
const askpass = @import("desktop").askpass;
const c = askpass.c;
const libc = @import("desktop").libc;
const assert = std.debug.assert;
const cast = c.__zig.cast;
fn pump() void {
    while (c.g_main_context_iteration(null, 0) != 0) {}
    c.g_usleep(1000);
}
extern fn g_object_weak_ref(*c.GObject, *const fn (?*anyopaque, ?*c.GObject) callconv(.c) void, ?*anyopaque) void;
fn finalized(data: ?*anyopaque, _: ?*c.GObject) callconv(.c) void {
    cast(bool, data).* = false;
}
fn checkEditing() !void {
    const dialog = try askpass.Dialog.create(.password, "Synthetic clipboard and editing checks");
    const entry = dialog.entry.?;
    entry.focus(true);
    const clipboard = c.gtk_clipboard_get_default(c.gtk_widget_get_display(dialog.canvas)).?;
    c.gtk_clipboard_set_text(clipboard, "paste-東京", -1);
    entry.paste();
    var deadline = c.g_get_monotonic_time() + 3_000_000;
    while (entry.refs > 1 and c.g_get_monotonic_time() < deadline) pump();
    try std.testing.expectEqualStrings("paste-東京", entry.buffer.value());
    try std.testing.expect(dialog.handleKey('a', c.GDK_CONTROL_MASK));
    try entry.insert("replacement");
    try std.testing.expectEqualStrings("replacement", entry.buffer.value());
    c.gtk_clipboard_set_text(clipboard, "clipboard-guard", -1);
    try std.testing.expect(dialog.handleKey('c', c.GDK_CONTROL_MASK));
    try std.testing.expect(dialog.handleKey('x', c.GDK_CONTROL_MASK));
    const Receipt = struct {
        done: bool = false,
        matches: bool = false,
        fn received(_: ?*c.GtkClipboard, value: [*c]const u8, data: c.gpointer) callconv(.c) void {
            const self = cast(@This(), data);
            self.done = true;
            self.matches = value != null and std.mem.eql(u8, std.mem.span(value), "clipboard-guard");
        }
    };
    var receipt: Receipt = .{};
    c.gtk_clipboard_request_text(clipboard, &Receipt.received, &receipt);
    while (!receipt.done and c.g_get_monotonic_time() < deadline) pump();
    try std.testing.expect(receipt.matches);
    try std.testing.expectEqualStrings("replacement", entry.buffer.value());
    // A late clipboard response must neither use the destroyed dialog nor
    // repopulate the password after clear/cancellation.
    entry.paste();
    dialog.clear();
    while (entry.refs > 1 and c.g_get_monotonic_time() < deadline) pump();
    try std.testing.expectEqualStrings("", entry.buffer.value());
    var live = true;
    g_object_weak_ref(cast(c.GObject, entry.im), &finalized, &live);
    entry.paste();
    dialog.destroy();
    deadline = c.g_get_monotonic_time() + 3_000_000;
    while (live and c.g_get_monotonic_time() < deadline) pump();
    try std.testing.expect(!live);
}
const Trigger = enum { response, enter, escape, allow_key, accept_click, cancel_click, term, interrupt };
const Response = struct {
    dialog: *askpass.Dialog,
    response: c_int,
    trigger: Trigger = .response,
    fn send(data: c.gpointer) callconv(.c) c.gboolean {
        const self: *Response = @ptrCast(@alignCast(data));
        switch (self.trigger) {
            .response => c.gtk_dialog_response(cast(c.GtkDialog, self.dialog.window), self.response),
            .enter => _ = self.dialog.handleKey(0xff0d, 0),
            .escape => _ = self.dialog.handleKey(0xff1b, 0),
            .allow_key => {
                _ = self.dialog.handleKey(0xff09, 0);
                _ = self.dialog.handleKey(0xff0d, 0);
            },
            .accept_click, .cancel_click => {
                const rect = self.dialog.view.buttonRect(if (self.trigger == .accept_click) .accept else .cancel);
                var event = std.mem.zeroes(c.GdkEventButton);
                event.type = c.GDK_BUTTON_PRESS;
                event.button = 1;
                event.x = rect.x + rect.width / 2;
                event.y = rect.y + rect.height / 2;
                var handled: c.gboolean = 0;
                c.g_signal_emit_by_name(self.dialog.canvas, "button-press-event", &event, &handled);
                event.type = 7;
                c.g_signal_emit_by_name(self.dialog.canvas, "button-release-event", &event, &handled);
            },
            .term => _ = libc.raise(libc.SIGTERM),
            .interrupt => _ = libc.raise(libc.SIGINT),
        }
        return 0;
    }
};
fn check(init: std.process.Init, root: []const u8, mode: askpass.Mode, response: c_int, expected: []const u8, status: u8, trigger: Trigger) !void {
    const prompt = "Enter passphrase for <test-key> at 100%: 東京";
    const dialog = try askpass.Dialog.create(mode, prompt);
    defer dialog.destroy();
    try std.testing.expectEqualStrings(prompt, dialog.prompt);
    if (dialog.entry) |entry| {
        try entry.insert("test-secret:$()\\ 東京");
    } else assert(mode != .password);
    var reply = Response{ .dialog = dialog, .response = response, .trigger = trigger };
    _ = c.g_timeout_add(25, &Response.send, &reply);
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
    if (dialog.entry) |entry| {
        try std.testing.expectEqualStrings("", entry.buffer.value());
        for (entry.buffer.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    c.gtk_init(null, null);
    try checkEditing();
    const root = c.g_dir_make_tmp("desktop-askpass-XXXXXX", null).?;
    defer c.g_free(root);
    defer std.Io.Dir.cwd().deleteTree(init.io, std.mem.span(root)) catch {};
    try std.testing.expectEqual(askpass.Mode.confirm, askpass.Mode.fromHint("confirm"));
    try std.testing.expectEqual(askpass.Mode.information, askpass.Mode.fromHint("none"));
    try std.testing.expectEqual(askpass.Mode.password, askpass.Mode.fromHint(null));
    try std.testing.expectEqual(askpass.Mode.password, askpass.Mode.fromHint("unknown"));
    try check(init, std.mem.span(root), .password, c.GTK_RESPONSE_OK, "test-secret:$()\\ 東京\n", 0, .response);
    try check(init, std.mem.span(root), .password, c.GTK_RESPONSE_CANCEL, "", 1, .response);
    try check(init, std.mem.span(root), .password, c.GTK_RESPONSE_DELETE_EVENT, "", 1, .response);
    try check(init, std.mem.span(root), .confirm, c.GTK_RESPONSE_OK, "yes\n", 0, .response);
    try check(init, std.mem.span(root), .confirm, c.GTK_RESPONSE_CANCEL, "", 1, .response);
    try check(init, std.mem.span(root), .information, c.GTK_RESPONSE_OK, "", 0, .enter);
    try check(init, std.mem.span(root), .password, c.GTK_RESPONSE_CANCEL, "", 1, .term);
    try check(init, std.mem.span(root), .password, c.GTK_RESPONSE_CANCEL, "", 1, .interrupt);
    try check(init, std.mem.span(root), .password, c.GTK_RESPONSE_OK, "test-secret:$()\\ 東京\n", 0, .enter);
    try check(init, std.mem.span(root), .password, c.GTK_RESPONSE_OK, "test-secret:$()\\ 東京\n", 0, .accept_click);
    try check(init, std.mem.span(root), .password, c.GTK_RESPONSE_CANCEL, "", 1, .cancel_click);
    try check(init, std.mem.span(root), .password, c.GTK_RESPONSE_CANCEL, "", 1, .escape);
    try check(init, std.mem.span(root), .confirm, c.GTK_RESPONSE_CANCEL, "", 1, .enter);
    try check(init, std.mem.span(root), .confirm, c.GTK_RESPONSE_OK, "yes\n", 0, .allow_key);
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
