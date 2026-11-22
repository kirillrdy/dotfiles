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
fn checkEditing(allocator: std.mem.Allocator) !void {
    const dialog = try askpass.Dialog.create(allocator, .password, "Synthetic clipboard and editing checks");
    const entry = dialog.entry.?;
    entry.focus(true);
    const clipboard = entry.clipboard().?;
    clipboard.copy("paste-東京");
    entry.paste();
    var deadline = c.__zig.monotonicTime() + 3_000_000;
    while (entry.refs > 1 and c.__zig.monotonicTime() < deadline) pump();
    try std.testing.expectEqualStrings("paste-東京", entry.buffer.value());
    try std.testing.expect(dialog.handleKey('a', c.__zig.control_mask));
    try entry.insert("replacement");
    try std.testing.expectEqualStrings("replacement", entry.buffer.value());
    clipboard.copy("clipboard-guard");
    try std.testing.expect(dialog.handleKey('c', c.__zig.control_mask));
    try std.testing.expect(dialog.handleKey('x', c.__zig.control_mask));
    const Receipt = struct {
        done: bool = false,
        matches: bool = false,
        fn received(data: ?*anyopaque, value: ?[]const u8) void {
            const self = cast(@This(), data);
            self.done = true;
            self.matches = value != null and std.mem.eql(u8, value.?, "clipboard-guard");
        }
    };
    var receipt: Receipt = .{};
    clipboard.paste(&Receipt.received, &receipt);
    while (!receipt.done and c.__zig.monotonicTime() < deadline) pump();
    try std.testing.expect(receipt.matches);
    try std.testing.expectEqualStrings("replacement", entry.buffer.value());
    // A late clipboard response must neither use the destroyed dialog nor
    // repopulate the password after clear/cancellation.
    entry.paste();
    dialog.clear();
    while (entry.refs > 1 and c.__zig.monotonicTime() < deadline) pump();
    try std.testing.expectEqualStrings("", entry.buffer.value());
    entry.paste();
    dialog.destroy();
    // Drain the outstanding clipboard request after the owner has been freed.
    deadline = c.__zig.monotonicTime() + 100_000;
    while (c.__zig.monotonicTime() < deadline) pump();
}
const Trigger = enum { response, enter, escape, allow_key, accept_click, cancel_click, term, interrupt };
const Response = struct {
    dialog: *askpass.Dialog,
    accepted: bool,
    trigger: Trigger = .response,
    fn send(data: c.gpointer) callconv(.c) c.gboolean {
        const self: *Response = @ptrCast(@alignCast(data));
        switch (self.trigger) {
            .response => self.dialog.respond(self.accepted),
            .enter => _ = self.dialog.handleKey(0xff0d, 0),
            .escape => _ = self.dialog.handleKey(0xff1b, 0),
            .allow_key => {
                _ = self.dialog.handleKey(0xff09, 0);
                _ = self.dialog.handleKey(0xff0d, 0);
            },
            .accept_click, .cancel_click => {
                const rect = self.dialog.view.buttonRect(if (self.trigger == .accept_click) .accept else .cancel);
                self.dialog.pointerButton(true, rect.x + rect.width / 2, rect.y + rect.height / 2 - self.dialog.offset);
                self.dialog.pointerButton(false, rect.x + rect.width / 2, rect.y + rect.height / 2 - self.dialog.offset);
            },
            .term => _ = libc.raise(libc.SIGTERM),
            .interrupt => _ = libc.raise(libc.SIGINT),
        }
        return 0;
    }
};
fn check(init: std.process.Init, root: []const u8, mode: askpass.Mode, accepted: bool, expected: []const u8, status: u8, trigger: Trigger) !void {
    const prompt = "Enter passphrase for <test-key> at 100%: 東京";
    const dialog = try askpass.Dialog.create(init.gpa, mode, prompt);
    defer dialog.destroy();
    try std.testing.expectEqualStrings(prompt, dialog.prompt);
    if (dialog.entry) |entry| {
        try entry.insert("test-secret:$()\\ 東京");
    } else assert(mode != .password);
    var reply = Response{ .dialog = dialog, .accepted = accepted, .trigger = trigger };
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
    try checkEditing(init.gpa);
    const root = try @import("desktop").paths.createTemporaryDirectory(arena.allocator(), "desktop-askpass-");
    defer std.Io.Dir.cwd().deleteTree(init.io, root) catch {};
    try std.testing.expectEqual(askpass.Mode.confirm, askpass.Mode.fromHint("confirm"));
    try std.testing.expectEqual(askpass.Mode.information, askpass.Mode.fromHint("none"));
    try std.testing.expectEqual(askpass.Mode.password, askpass.Mode.fromHint(null));
    try std.testing.expectEqual(askpass.Mode.password, askpass.Mode.fromHint("unknown"));
    try check(init, root, .password, true, "test-secret:$()\\ 東京\n", 0, .response);
    try check(init, root, .password, false, "", 1, .response);
    try check(init, root, .confirm, true, "yes\n", 0, .response);
    try check(init, root, .confirm, false, "", 1, .response);
    try check(init, root, .information, true, "", 0, .enter);
    try check(init, root, .password, false, "", 1, .term);
    try check(init, root, .password, false, "", 1, .interrupt);
    try check(init, root, .password, true, "test-secret:$()\\ 東京\n", 0, .enter);
    try check(init, root, .password, true, "test-secret:$()\\ 東京\n", 0, .accept_click);
    try check(init, root, .password, false, "", 1, .cancel_click);
    try check(init, root, .password, false, "", 1, .escape);
    try check(init, root, .confirm, false, "", 1, .enter);
    try check(init, root, .confirm, true, "yes\n", 0, .allow_key);
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
