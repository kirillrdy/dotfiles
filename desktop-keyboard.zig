//! Keymap, modifier and Compose handling shared by native Wayland clients,
//! on the Zig XKB implementation in desktop-xkb.zig.
const std = @import("std");
const libc = @import("desktop-libc.zig");
const xkb = @import("desktop-xkb.zig");
const runtime = @import("desktop-runtime.zig");

/// X keysyms used by the native key handlers.
pub const keys = struct {
    pub const BackSpace: c_int = 0xff08;
    pub const Return: c_int = 0xff0d;
    pub const Escape: c_int = 0xff1b;
    pub const Left: c_int = 0xff51;
    pub const Up: c_int = 0xff52;
    pub const Right: c_int = 0xff53;
    pub const Down: c_int = 0xff54;
    pub const Page_Up: c_int = 0xff55;
    pub const Page_Down: c_int = 0xff56;
    pub const KP_Enter: c_int = 0xff8d;
    pub const Super_L: c_int = 0xffeb;
    pub const Super_R: c_int = 0xffec;
};
/// Modifier bits, at the positions X and GDK use.
pub const Modifiers = c_uint;
pub const shift = 1;
pub const control = 4;
pub const alt = 8;
pub const super = 1 << 26;
pub const Keyboard = struct {
    map: ?*xkb.Keymap = null,
    state: ?xkb.State = null,
    table: ?*xkb.ComposeTable = null,
    compose: ?xkb.Compose = null,
    pub fn deinit(self: *Keyboard) void {
        if (self.table) |table| table.deinit();
        if (self.map) |map| map.deinit();
        self.* = .{};
    }
    pub fn load(self: *Keyboard, fd: c_int, format: u32, size: u32) void {
        defer _ = libc.close(fd);
        self.deinit();
        if (format != 1 or size == 0 or size > 16 * 1024 * 1024) return;
        // wl_keyboard v7: the keymap fd may be sealed read-only, so it is mapped privately.
        const memory = libc.mmap(null, size, libc.PROT_READ, libc.MAP_PRIVATE, fd, 0);
        if (memory == null or memory == libc.MAP_FAILED) return;
        defer _ = libc.munmap(memory, size);
        const bytes: [*]const u8 = @ptrCast(memory);
        if (bytes[size - 1] != 0) return;
        const map = xkb.Keymap.parse(std.heap.c_allocator, bytes[0 .. size - 1]) catch return;
        self.map = map;
        self.state = .{ .keymap = map };
        var locale: []const u8 = "C";
        for ([_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
            const value = libc.getenv(name);
            if (value != null and value[0] != 0) {
                locale = std.mem.span(value);
                break;
            }
        }
        const directory: []const u8 = if (libc.getenv("XLOCALEDIR")) |value| std.mem.span(value) else runtime.xlocale_dir orelse "/usr/share/X11/locale";
        const table = xkb.ComposeTable.load(std.heap.c_allocator, directory, locale) orelse return;
        self.table = table;
        self.compose = .{ .table = table };
    }
    pub fn update(self: *Keyboard, depressed: u32, latched: u32, locked: u32, group: u32) void {
        if (self.state) |*state| state.update(depressed, latched, locked, group);
    }
    pub fn modifiers(self: *const Keyboard) u32 {
        const state = self.state orelse return 0;
        var result: u32 = 0;
        for ([_][]const u8{ "Shift", "Control", "Mod1", "Mod4" }, [_]u32{ shift, control, alt, super }) |name, bit| {
            if (state.active(name)) result |= bit;
        }
        return result;
    }
    pub fn capsLock(self: *const Keyboard) bool {
        return if (self.state) |state| state.active("Lock") else false;
    }
    pub fn symbol(self: *const Keyboard, code: u32) u32 {
        return if (self.state) |state| state.keysym(code +| 8) else 0;
    }
    pub fn repeats(self: *const Keyboard, code: u32) bool {
        return if (self.map) |map| map.repeats(code +| 8) else false;
    }
    pub fn reset(self: *Keyboard) void {
        if (self.compose) |*compose| compose.reset();
    }
    /// Temporary UTF-8 storage belongs to the caller and can be securely erased
    /// after a password entry has consumed it.
    pub fn text(self: *Keyboard, code: u32, buffer: *[128]u8) []const u8 {
        const state = self.state orelse return "";
        if (self.modifiers() & (control | alt | super) != 0) return "";
        var value: []const u8 = undefined;
        if (self.compose) |*compose| {
            switch (compose.feed(self.symbol(code))) {
                .composing => return "", // A dead key or Compose sequence is in progress.
                .composed => {
                    value = compose.utf8(buffer);
                    compose.reset();
                },
                .cancelled => {
                    compose.reset();
                    return "";
                },
                .nothing => value = state.utf8(code +| 8, buffer),
            }
        } else value = state.utf8(code +| 8, buffer);
        if (value.len == 0 or value.len >= buffer.len) return "";
        if (std.mem.indexOfAny(u8, value, "\x00\r\n") != null) return "";
        for (value) |byte| if (byte < 32 or byte == 127) return "";
        return value;
    }
};

pub fn unicode(symbol: u32) u32 {
    return xkb.toUnicode(symbol);
}

test "native XKB input follows modifiers, composes accents and suppresses control text" {
    // Compiled by xkbcommon (xkbcli compile-keymap --layout us --variant intl).
    const keymap = @embedFile("tests/xkb/us-intl.xkb");
    const fd = libc.memfd_create("native-keyboard-test", libc.MFD_CLOEXEC);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(isize, @intCast(keymap.len + 1)), libc.write(fd, keymap.ptr, keymap.len + 1));
    var keyboard: Keyboard = .{};
    defer keyboard.deinit();
    keyboard.load(fd, 1, @intCast(keymap.len + 1));
    try std.testing.expect(keyboard.state != null);
    try std.testing.expect(keyboard.compose != null);
    var buffer: [128]u8 = @splat(0);
    try std.testing.expectEqualStrings("a", keyboard.text(30, &buffer));
    keyboard.update(1, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, shift), keyboard.modifiers());
    try std.testing.expectEqualStrings("A", keyboard.text(30, &buffer));
    keyboard.update(4, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, control), keyboard.modifiers());
    try std.testing.expectEqualStrings("", keyboard.text(30, &buffer));
    keyboard.update(0, 0, 0, 0);
    try std.testing.expectEqualStrings("", keyboard.text(40, &buffer));
    try std.testing.expectEqualStrings("é", keyboard.text(18, &buffer));
    try std.testing.expectEqualStrings("a", keyboard.text(30, &buffer));
    // AltGr (Mod5) reaches the third level of us(intl).
    keyboard.update(1 << 7, 0, 0, 0);
    try std.testing.expectEqualStrings("é", keyboard.text(18, &buffer));
    keyboard.update(0, 0, 0, 0);
    try std.testing.expect(keyboard.repeats(30));
    try std.testing.expect(!keyboard.repeats(42));
    try std.testing.expectEqual(@as(u32, keys.Return), keyboard.symbol(28));
}
