//! Locked native entry. Masked responses never enter text layouts; PAM can opt into echo.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const libc = @import("desktop-libc.zig");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const cast = c.__zig.cast;
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;

pub const Buffer = struct {
    pub const capacity = 4096;
    bytes: [capacity]u8 = @splat(0),
    len: usize = 0,
    cursor: usize = 0,
    anchor: usize = 0,

    pub fn create() !*Buffer {
        // Separate pages avoid unlocking another entry's allocation on teardown.
        const self = try std.heap.page_allocator.create(Buffer);
        errdefer std.heap.page_allocator.destroy(self);
        if (libc.mlock(self, @sizeOf(Buffer)) != 0) return error.SecretMemoryLockFailed;
        self.* = .{};
        return self;
    }
    pub fn destroy(self: *Buffer) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
        _ = libc.munlock(self, @sizeOf(Buffer));
        std.heap.page_allocator.destroy(self);
    }
    pub fn clear(self: *Buffer) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
        self.cursor = 0;
        self.anchor = 0;
    }
    pub fn value(self: *const Buffer) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn selectAll(self: *Buffer) void {
        self.anchor = 0;
        self.cursor = self.len;
    }
    pub fn selected(self: *const Buffer) bool {
        return self.anchor != self.cursor;
    }
    fn previous(self: *const Buffer, offset: usize) usize {
        if (offset == 0) return 0;
        var result = offset - 1;
        while (result > 0 and self.bytes[result] & 0xc0 == 0x80) result -= 1;
        return result;
    }
    fn next(self: *const Buffer, offset: usize) usize {
        if (offset == self.len) return self.len;
        var result = offset + 1;
        while (result < self.len and self.bytes[result] & 0xc0 == 0x80) result += 1;
        return result;
    }
    pub fn move(self: *Buffer, forward: bool, extend: bool, word: bool) void {
        if (!extend and self.selected()) self.cursor = if (forward) @max(self.cursor, self.anchor) else @min(self.cursor, self.anchor) else {
            var position = if (forward) self.next(self.cursor) else self.previous(self.cursor);
            if (word) {
                while (position > 0 and position < self.len and self.bytes[position] != ' ' and self.bytes[position] != '\t') position = if (forward) self.next(position) else self.previous(position);
            }
            self.cursor = position;
        }
        if (!extend) self.anchor = self.cursor;
    }
    pub fn end(self: *Buffer, forward: bool, extend: bool) void {
        self.cursor = if (forward) self.len else 0;
        if (!extend) self.anchor = self.cursor;
    }
    pub fn insert(self: *Buffer, value_to_insert: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(value_to_insert) or std.mem.indexOfAny(u8, value_to_insert, "\x00\r\n") != null) return error.InvalidText;
        const start = @min(self.cursor, self.anchor);
        const finish = @max(self.cursor, self.anchor);
        const new_len = self.len - (finish - start) + value_to_insert.len;
        if (new_len > capacity) return error.PasswordTooLong;
        const destination = self.bytes[start + value_to_insert.len .. new_len];
        const tail = self.bytes[finish..self.len];
        if (value_to_insert.len > finish - start) std.mem.copyBackwards(u8, destination, tail) else std.mem.copyForwards(u8, destination, tail);
        @memcpy(self.bytes[start..][0..value_to_insert.len], value_to_insert);
        if (new_len < self.len) std.crypto.secureZero(u8, self.bytes[new_len..self.len]);
        self.len = new_len;
        self.cursor = start + value_to_insert.len;
        self.anchor = self.cursor;
    }
    pub fn erase(self: *Buffer, forward: bool, word: bool) void {
        if (!self.selected()) self.move(forward, true, word);
        self.insert("") catch unreachable;
    }
    pub fn characters(self: *const Buffer, offset: usize) usize {
        var result: usize = 0;
        for (self.bytes[0..offset]) |byte| if (byte & 0xc0 != 0x80) {
            result += 1;
        };
        return result;
    }
    pub fn byteOffset(self: *const Buffer, character: usize) usize {
        var result: usize = 0;
        for (0..character) |_| result = self.next(result);
        return result;
    }
};

pub const Rect = struct { x: f64, y: f64, width: f64, height: f64 };
pub const Entry = struct {
    buffer: *Buffer,
    widget: *c.GtkWidget,
    im: *c.GtkIMContext,
    changed: *const fn (?*anyopaque) void,
    data: ?*anyopaque,
    rect: Rect = .{ .x = 0, .y = 0, .width = 400, .height = 42 },
    focused: bool = false,
    // Only PAM ECHO_ON challenges opt into visible, uncached glyphs.
    echo: bool = false,
    dragging: bool = false,
    caret: bool = true,
    blink: c.guint = 0,
    preedit: usize = 0,
    first: usize = 0,
    advance: f64 = 10,
    renderer: text.Renderer = .{},
    bullet: ?text.Mask = null,
    scale: u32 = 0,
    refs: usize = 1,
    revision: u64 = 0,
    dead: bool = false,

    pub fn create(widget: *c.GtkWidget, changed: *const fn (?*anyopaque) void, data: ?*anyopaque) !*Entry {
        const self = try a.create(Entry);
        errdefer a.destroy(self);
        const buffer = try Buffer.create();
        errdefer buffer.destroy();
        const im = c.gtk_im_multicontext_new() orelse return error.InputMethod;
        self.* = .{ .buffer = buffer, .widget = widget, .im = im, .changed = changed, .data = data };
        c.g_object_set(im, "input-purpose", @as(c_int, c.GTK_INPUT_PURPOSE_PASSWORD), "input-hints", @as(c_int, c.GTK_INPUT_HINT_NO_SPELLCHECK), @as(?*anyopaque, null));
        self.connect(im, "commit", &commit);
        self.connect(im, "preedit-changed", &preeditChanged);
        self.connect(im, "retrieve-surrounding", &surrounding);
        self.connect(widget, "realize", &realized);
        self.connect(widget, "unrealize", &unrealized);
        if (c.gtk_widget_get_window(widget)) |window| c.gtk_im_context_set_client_window(im, window);
        return self;
    }
    fn connect(self: *Entry, object: anytype, signal: [*:0]const u8, callback: anytype) void {
        _ = c.g_signal_connect_data(object, signal, @ptrCast(callback), self, null, 0);
    }
    fn realized(_: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
        const self = cast(Entry, data);
        c.gtk_im_context_set_client_window(self.im, c.gtk_widget_get_window(self.widget));
        if (self.focused) c.gtk_im_context_focus_in(self.im);
    }
    fn unrealized(_: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
        c.gtk_im_context_set_client_window(cast(Entry, data).im, null);
    }
    fn commit(_: *c.GtkIMContext, value_to_insert: [*c]const u8, data: c.gpointer) callconv(.c) void {
        const self = cast(Entry, data);
        if (self.dead or !self.focused) return;
        self.insert(std.mem.span(value_to_insert)) catch {};
    }
    fn preeditChanged(_: *c.GtkIMContext, data: c.gpointer) callconv(.c) void {
        const self = cast(Entry, data);
        if (self.dead) return;
        var value_to_count: [*c]u8 = null;
        var attrs: ?*c.PangoAttrList = null;
        var cursor: c.gint = 0;
        c.gtk_im_context_get_preedit_string(self.im, &value_to_count, &attrs, &cursor);
        defer if (attrs) |value| text.api.pango_attr_list_unref(@ptrCast(value));
        self.preedit = 0;
        if (value_to_count != null) {
            const bytes = std.mem.span(value_to_count);
            for (bytes) |byte| if (byte & 0xc0 != 0x80) {
                self.preedit += 1;
            };
            std.crypto.secureZero(u8, bytes);
            c.g_free(value_to_count);
        }
        self.notify();
    }
    fn surrounding(context: *c.GtkIMContext, _: c.gpointer) callconv(.c) c.gboolean {
        // Input methods must not receive the password as surrounding text.
        c.gtk_im_context_set_surrounding(context, "", 0, 0);
        return 1;
    }
    pub fn focus(self: *Entry, focused: bool) void {
        if (self.focused == focused or self.dead) return;
        self.focused = focused;
        if (focused) {
            c.gtk_im_context_focus_in(self.im);
            self.blink = c.g_timeout_add(500, &tick, self);
        } else {
            c.gtk_im_context_reset(self.im);
            c.gtk_im_context_focus_out(self.im);
            self.preedit = 0;
            self.dragging = false;
            if (self.blink != 0) _ = c.g_source_remove(self.blink);
            self.blink = 0;
        }
        self.notify();
    }
    fn tick(data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Entry, data);
        self.caret = !self.caret;
        self.changed(self.data);
        return 1;
    }
    fn notify(self: *Entry) void {
        self.caret = true;
        self.changed(self.data);
    }
    pub fn clear(self: *Entry) void {
        self.buffer.clear();
        self.preedit = 0;
        self.first = 0;
        self.revision += 1;
        c.gtk_im_context_reset(self.im);
        if (!self.dead) self.notify();
    }
    pub fn insert(self: *Entry, value_to_insert: []const u8) !void {
        try self.buffer.insert(value_to_insert);
        self.revision += 1;
        self.preedit = 0;
        self.notify();
    }
    pub fn filter(self: *Entry, event: *c.GdkEvent) bool {
        return self.focused and c.gtk_im_context_filter_keypress(self.im, @ptrCast(event)) != 0;
    }
    pub fn key(self: *Entry, symbol: u32, modifiers: c.GdkModifierType) bool {
        const control = modifiers & c.GDK_CONTROL_MASK != 0;
        const shift = modifiers & c.GDK_SHIFT_MASK != 0;
        switch (symbol) {
            0xff51, 0xff53 => {
                self.resetComposition();
                self.buffer.move(symbol == 0xff53, shift, control);
            },
            0xff50, 0xff57 => {
                self.resetComposition();
                self.buffer.end(symbol == 0xff57, shift);
            },
            0xff08, 0xffff => {
                self.resetComposition();
                self.buffer.erase(symbol == 0xffff, control);
            },
            'a', 'A' => {
                if (!control) return false;
                self.resetComposition();
                self.buffer.selectAll();
            },
            'u', 'U' => {
                if (!control) return false;
                self.resetComposition();
                self.buffer.end(false, true);
                self.buffer.erase(false, false);
            },
            'k', 'K' => {
                if (!control) return false;
                self.resetComposition();
                self.buffer.end(true, true);
                self.buffer.erase(true, false);
            },
            'w', 'W' => {
                if (!control) return false;
                self.resetComposition();
                self.buffer.erase(false, true);
            },
            'c', 'C', 'x', 'X' => return control, // Never export a password to the clipboard.
            'v', 'V' => {
                if (!control) return false;
                self.paste();
                return true;
            },
            0xff63 => {
                if (!shift) return false;
                self.paste();
                return true;
            },
            else => return false,
        }
        self.revision += 1;
        self.notify();
        return true;
    }
    const Paste = struct { entry: *Entry, revision: u64 };
    fn resetComposition(self: *Entry) void {
        if (self.preedit > 0) c.gtk_im_context_reset(self.im);
        self.preedit = 0;
    }
    pub fn paste(self: *Entry) void {
        self.resetComposition();
        const clipboard = c.gtk_clipboard_get_default(c.gtk_widget_get_display(self.widget)) orelse return;
        const request = a.create(Paste) catch return;
        request.* = .{ .entry = self, .revision = self.revision };
        self.refs += 1;
        c.gtk_clipboard_request_text(clipboard, &pasted, request);
    }
    fn pasted(_: ?*c.GtkClipboard, value_to_insert: [*c]const u8, data: c.gpointer) callconv(.c) void {
        const request = cast(Paste, data);
        const self = request.entry;
        defer self.release();
        defer a.destroy(request);
        if (!self.dead and self.focused and self.revision == request.revision and value_to_insert != null) self.insert(std.mem.span(value_to_insert)) catch {};
    }
    pub fn point(self: *Entry, x: f64, extend: bool) void {
        self.resetComposition();
        const character: usize = @intFromFloat(@max(0, @round((x - self.rect.x - 12) / self.advance) + @as(f64, @floatFromInt(self.first))));
        self.buffer.cursor = self.buffer.byteOffset(@min(character, self.buffer.characters(self.buffer.len)));
        if (!extend) self.buffer.anchor = self.buffer.cursor;
        self.revision += 1;
        self.notify();
    }
    pub fn paint(self: *Entry, target: raster.Buffer, scale: u32) !void {
        if (self.scale != scale) {
            if (self.bullet) |mask| mask.deinit(a);
            self.bullet = null;
            self.scale = 0;
            self.bullet = try self.renderer.renderLayout(a, "●", .{ .size = 12 * @as(f64, @floatFromInt(scale)), .dpi = 96 * @as(f64, @floatFromInt(scale)), .origin = .top });
            self.scale = scale;
            self.advance = @as(f64, @floatFromInt(self.bullet.?.logical_width)) / @as(f64, @floatFromInt(scale)) + 2;
        }
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        const rect = self.rect;
        canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height }, .radius = 9 } }}, color(0x242427));
        canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = rect.x + 1, .y = rect.y + 1, .width = rect.width - 2, .height = rect.height - 2 }, .radius = 8, .width = if (self.focused) 2 else 1 } }}, color(if (self.focused) 0x78aeed else 0x606066));
        const cursor = self.buffer.characters(self.buffer.cursor);
        const anchor = self.buffer.characters(self.buffer.anchor);
        const visible: usize = @intFromFloat(@max(1, @floor((rect.width - 28) / self.advance)));
        const caret_index = cursor + self.preedit;
        if (caret_index < self.first) self.first = caret_index;
        if (caret_index >= self.first + visible) self.first = caret_index - visible + 1;
        const total = self.buffer.characters(self.buffer.len) + self.preedit;
        const last = @min(total, self.first + visible);
        for (self.first..@max(self.first, last)) |index| {
            const x = rect.x + 12 + @as(f64, @floatFromInt(index - self.first)) * self.advance;
            if (index >= @min(cursor, anchor) and index < @max(cursor, anchor)) canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = x, .y = rect.y + 9, .width = self.advance, .height = rect.height - 18 }, .radius = 0 } }}, color(0x3584e4));
            var glyph: ?text.Mask = null;
            defer if (glyph) |mask| mask.deinit(a);
            if (self.echo and index < self.buffer.characters(self.buffer.len)) {
                const start = self.buffer.byteOffset(index);
                const end = self.buffer.byteOffset(index + 1);
                var bytes: [4:0]u8 = @splat(0);
                defer std.crypto.secureZero(u8, &bytes);
                const len = end - start;
                @memcpy(bytes[0..len], self.buffer.bytes[start..end]);
                glyph = try self.renderer.renderLayout(a, bytes[0..len :0], .{ .font = "monospace", .size = 14.666 * canvas.scale, .dpi = 96 * canvas.scale, .width = @intFromFloat(self.advance * canvas.scale), .lines = 1, .origin = .top });
            }
            const mask = glyph orelse self.bullet.?;
            raster.mask(target, .{ .x = @as(i32, @intFromFloat(x * canvas.scale)) + mask.left, .y = @as(i32, @intFromFloat((rect.y + (rect.height - @as(f64, @floatFromInt(mask.logical_height)) / canvas.scale) / 2) * canvas.scale)) + mask.top, .width = mask.width, .height = mask.height }, mask.pixels, color(0xffffff));
        }
        const caret_x = rect.x + 12 + @as(f64, @floatFromInt(caret_index - self.first)) * self.advance;
        if (self.focused and self.caret) canvas.draw(&.{.{ .line = .{ .start = .{ .x = caret_x, .y = rect.y + 11 }, .end = .{ .x = caret_x, .y = rect.y + rect.height - 11 }, .radius = 0.65 } }}, color(0xffffff));
        const location: c.GdkRectangle = .{ .x = @intFromFloat(caret_x), .y = @intFromFloat(rect.y), .width = 1, .height = @intFromFloat(rect.height) };
        c.gtk_im_context_set_cursor_location(self.im, &location);
    }
    pub fn destroy(self: *Entry) void {
        self.dead = true;
        self.clear();
        if (self.blink != 0) _ = c.g_source_remove(self.blink);
        _ = c.g_signal_handlers_disconnect_matched(self.widget, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        _ = c.g_signal_handlers_disconnect_matched(self.im, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_im_context_focus_out(self.im);
        c.gtk_im_context_set_client_window(self.im, null);
        self.release();
    }
    fn release(self: *Entry) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.buffer.destroy();
        if (self.bullet) |mask| mask.deinit(a);
        self.renderer.deinit();
        c.g_object_unref(self.im);
        a.destroy(self);
    }
};
fn color(value: u32) raster.Color {
    return .{ .red = @as(f64, @floatFromInt((value >> 16) & 255)) / 255, .green = @as(f64, @floatFromInt((value >> 8) & 255)) / 255, .blue = @as(f64, @floatFromInt(value & 255)) / 255 };
}

test "password buffer edits Unicode selections, rejects invalid input atomically, and erases removed bytes" {
    var buffer: Buffer = .{};
    defer buffer.clear();
    try buffer.insert("a日本🔑z");
    buffer.move(false, false, false);
    buffer.erase(false, false);
    try std.testing.expectEqualStrings("a日本z", buffer.value());
    buffer.move(false, true, false);
    try buffer.insert("é");
    try std.testing.expectEqualStrings("a日éz", buffer.value());
    buffer.end(false, false);
    buffer.erase(true, false);
    try std.testing.expectEqualStrings("日éz", buffer.value());
    try std.testing.expectError(error.InvalidText, buffer.insert("\xff"));
    try std.testing.expectError(error.InvalidText, buffer.insert("secret\nnext"));
    try std.testing.expectError(error.PasswordTooLong, buffer.insert(&@as([Buffer.capacity]u8, @splat('x'))));
    try std.testing.expectEqualStrings("日éz", buffer.value());
    buffer.selectAll();
    try buffer.insert("x");
    for (buffer.bytes[1..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    buffer.clear();
    try std.testing.expectEqual(@as(usize, 0), buffer.len);
    for (buffer.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "native password pixels depend on character count rather than plaintext" {
    c.gtk_init(null, null);
    const canvas = c.gtk_drawing_area_new().?;
    _ = c.g_object_ref_sink(canvas);
    defer c.g_object_unref(canvas);
    defer c.gtk_widget_destroy(canvas);
    const Callback = struct {
        fn changed(_: ?*anyopaque) void {}
    };
    const entry = try Entry.create(canvas, &Callback.changed, null);
    defer entry.destroy();
    entry.focus(true);
    for ([_]u32{ 1, 2 }) |scale| {
        const width = 400 * scale;
        const height = 42 * scale;
        const first = try std.testing.allocator.alloc(u32, width * height);
        defer std.testing.allocator.free(first);
        const second = try std.testing.allocator.alloc(u32, width * height);
        defer std.testing.allocator.free(second);
        @memset(first, 0);
        @memset(second, 0);
        entry.clear();
        try entry.insert("hunter2");
        try entry.paint(.{ .pixels = first, .width = width, .height = height }, scale);
        entry.clear();
        try entry.insert("秘密abcde");
        try entry.paint(.{ .pixels = second, .width = width, .height = height }, scale);
        try std.testing.expectEqualSlices(u32, first, second);
        // PAM ECHO_ON draws visible glyphs; returning to ECHO_OFF restores
        // identical masked pixels without retaining a plaintext layout.
        entry.echo = true;
        @memset(second, 0);
        try entry.paint(.{ .pixels = second, .width = width, .height = height }, scale);
        try std.testing.expect(!std.mem.eql(u32, first, second));
        entry.echo = false;
        @memset(second, 0);
        try entry.paint(.{ .pixels = second, .width = width, .height = height }, scale);
        try std.testing.expectEqualSlices(u32, first, second);
    }
    entry.clear();
    // Exercise the same commit signal that input-method composition uses.
    c.g_signal_emit_by_name(entry.im, "commit", @as([*:0]const u8, "東京🔑"));
    try std.testing.expectEqualStrings("東京🔑", entry.buffer.value());
    var surrounding_text: [*c]u8 = null;
    var cursor: c.gint = -1;
    try std.testing.expect(c.gtk_im_context_get_surrounding(entry.im, &surrounding_text, &cursor) != 0);
    defer c.g_free(surrounding_text);
    try std.testing.expectEqualStrings("", std.mem.span(surrounding_text));
    try std.testing.expectEqual(@as(c.gint, 0), cursor);
    try std.testing.expect(entry.key('a', c.GDK_CONTROL_MASK));
    try entry.insert("x");
    try std.testing.expectEqualStrings("x", entry.buffer.value());
    for (entry.buffer.bytes[1..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
