//! Public search editing independent of GTK widgets and GDK events.
const std = @import("std");
const c = @import("desktop-gtk.zig");
pub const Buffer = @import("desktop-password-entry.zig").Buffer;
const a = std.heap.c_allocator;
const cast = c.__zig.cast;
pub const Entry = struct {
    buffer: *Buffer,
    focused: bool = false,
    caret: bool = true,
    dragging: bool = false,
    revision: u64 = 0,
    composition: Buffer = .{},
    composition_cursor: usize = 0,
    composition_caret: bool = true,
    blink: c.guint = 0,
    refs: usize = 1,
    dead: bool = false,
    changed: *const fn (?*anyopaque) void,
    data: ?*anyopaque,

    pub fn create(changed: *const fn (?*anyopaque) void, data: ?*anyopaque) !*Entry {
        const self = try a.create(Entry);
        errdefer a.destroy(self);
        const buffer = try a.create(Buffer);
        buffer.* = .{};
        self.* = .{ .buffer = buffer, .changed = changed, .data = data };
        return self;
    }
    pub fn destroy(self: *Entry) void {
        self.focus(false);
        self.dead = true;
        self.release();
    }
    fn release(self: *Entry) void {
        self.refs -= 1;
        if (self.refs == 0) {
            a.destroy(self.buffer);
            a.destroy(self);
        }
    }
    fn notify(self: *Entry) void {
        self.caret = true;
        self.revision +%= 1;
        if (!self.dead) self.changed(self.data);
    }
    pub fn focus(self: *Entry, value: bool) void {
        if (self.focused == value or self.dead) return;
        self.focused = value;
        if (value) self.blink = c.g_timeout_add(500, &tick, self) else {
            if (self.blink != 0) _ = c.g_source_remove(self.blink);
            self.blink = 0;
            self.composition.clear();
            self.dragging = false;
        }
        self.notify();
    }
    fn tick(data: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Entry, data);
        self.caret = !self.caret;
        self.changed(self.data);
        return 1;
    }
    pub fn clear(self: *Entry) void {
        self.buffer.clear();
        self.composition.clear();
        self.notify();
    }
    pub fn insert(self: *Entry, value: []const u8) !void {
        try self.buffer.insert(value);
        self.composition.clear();
        self.notify();
    }
    pub fn preedit(self: *Entry, value: []const u8, cursor: i32) void {
        var replacement: Buffer = .{};
        replacement.insert(value) catch return;
        if (cursor < -1 or cursor > value.len) return;
        if (cursor >= 0 and cursor < value.len and value[@intCast(cursor)] & 0xc0 == 0x80) return;
        self.composition = replacement;
        self.composition_cursor = if (cursor < 0) value.len else @intCast(cursor);
        self.composition_caret = cursor >= 0;
        self.notify();
    }
    pub fn presentation(self: *Entry) Buffer {
        var buffer = self.buffer.*;
        if (self.composition.len > 0) {
            const start = @min(buffer.cursor, buffer.anchor);
            buffer.insert(self.composition.value()) catch return self.buffer.*;
            buffer.cursor = start + self.composition_cursor;
            buffer.anchor = buffer.cursor;
        }
        return buffer;
    }
    pub fn deleteSurrounding(self: *Entry, before: u32, after: u32) void {
        const cursor = self.buffer.cursor;
        if (before > cursor or after > self.buffer.len - cursor) return;
        const start = cursor - before;
        const end = cursor + after;
        const bytes = self.buffer.value();
        if ((start < bytes.len and bytes[start] & 0xc0 == 0x80) or (end < bytes.len and bytes[end] & 0xc0 == 0x80)) return;
        self.buffer.cursor = start;
        self.buffer.anchor = end;
        self.buffer.insert("") catch return;
        self.notify();
    }
    pub fn key(self: *Entry, symbol: u32, modifiers: u32) bool {
        const control = modifiers & 4 != 0;
        const shift = modifiers & 1 != 0;
        switch (symbol) {
            0xff51, 0xff53 => self.buffer.move(symbol == 0xff53, shift, control),
            0xff50, 0xff57 => self.buffer.end(symbol == 0xff57, shift),
            0xff08, 0xffff => self.buffer.erase(symbol == 0xffff, control),
            'a', 'A' => {
                if (!control) return false;
                self.buffer.selectAll();
            },
            'u', 'U' => {
                if (!control) return false;
                self.buffer.end(false, true);
                self.buffer.erase(false, false);
            },
            'k', 'K' => {
                if (!control) return false;
                self.buffer.end(true, true);
                self.buffer.erase(true, false);
            },
            'w', 'W' => {
                if (!control) return false;
                self.buffer.erase(false, true);
            },
            'c', 'C', 'x', 'X' => {
                if (!control) return false;
                if (!self.buffer.selected()) return true;
                const clipboard = c.gtk_clipboard_get_default(c.gdk_display_get_default()) orelse return true;
                const start = @min(self.buffer.cursor, self.buffer.anchor);
                const end = @max(self.buffer.cursor, self.buffer.anchor);
                c.gtk_clipboard_set_text(clipboard, self.buffer.bytes[start..end].ptr, @intCast(end - start));
                if (symbol == 'x' or symbol == 'X') self.buffer.erase(false, false);
            },
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
        self.composition.clear();
        self.notify();
        return true;
    }
    const Paste = struct { entry: *Entry, revision: u64 };
    fn paste(self: *Entry) void {
        const clipboard = c.gtk_clipboard_get_default(c.gdk_display_get_default()) orelse return;
        const request = a.create(Paste) catch return;
        request.* = .{ .entry = self, .revision = self.revision };
        self.refs += 1;
        c.gtk_clipboard_request_text(clipboard, &pasted, request);
    }
    fn pasted(_: ?*c.GtkClipboard, value: [*c]const u8, data: ?*anyopaque) callconv(.c) void {
        const request = cast(Paste, data);
        const self = request.entry;
        defer self.release();
        defer a.destroy(request);
        if (!self.dead and self.focused and self.revision == request.revision and value != null) self.insert(std.mem.span(value)) catch {};
    }
};

test "native search composes without changing the committed query and validates UTF-8 deletions" {
    const Observer = struct {
        fn changed(_: ?*anyopaque) void {}
    };
    const entry = try Entry.create(&Observer.changed, null);
    defer entry.destroy();
    try entry.insert("日本語");
    entry.preedit("とうきょう", 15);
    try std.testing.expectEqualStrings("日本語", entry.buffer.value());
    const pending = entry.presentation();
    try std.testing.expectEqualStrings("日本語とうきょう", pending.value());
    entry.preedit("", -1);
    try std.testing.expectEqual(@as(usize, 0), entry.composition.len);
    entry.preedit("とうきょう", -1);
    try std.testing.expect(!entry.composition_caret);
    try entry.insert("東京");
    try std.testing.expectEqualStrings("日本語東京", entry.buffer.value());
    try std.testing.expectEqual(@as(usize, 0), entry.composition.len);
    entry.deleteSurrounding(1, 0); // Reject a split UTF-8 codepoint.
    try std.testing.expectEqualStrings("日本語東京", entry.buffer.value());
    entry.deleteSurrounding(6, 0);
    try std.testing.expectEqualStrings("日本語", entry.buffer.value());
    try std.testing.expect(entry.key('a', 4));
    try entry.insert("café");
    try std.testing.expect(entry.key(0xff08, 0));
    try std.testing.expectEqualStrings("caf", entry.buffer.value());
}
