//! XKB keymap, modifier and compose handling shared by native Wayland clients.
const std = @import("std");
const libc = @import("desktop-libc.zig");
pub const Context = opaque {};
pub const Keymap = opaque {};
pub const State = opaque {};
const ComposeTable = opaque {};
const Compose = opaque {};
pub extern fn xkb_context_new(c_int) ?*Context;
pub extern fn xkb_context_unref(?*Context) void;
pub extern fn xkb_keymap_new_from_string(*Context, [*:0]const u8, c_int, c_int) ?*Keymap;
pub extern fn xkb_keymap_unref(?*Keymap) void;
pub extern fn xkb_state_new(*Keymap) ?*State;
pub extern fn xkb_state_unref(?*State) void;
pub extern fn xkb_state_update_mask(*State, u32, u32, u32, u32, u32, u32) c_int;
extern fn xkb_state_mod_name_is_active(*State, [*:0]const u8, c_int) c_int;
pub extern fn xkb_state_key_get_one_sym(*State, u32) u32;
pub extern fn xkb_state_key_get_utf8(*State, u32, [*]u8, usize) c_int;
extern fn xkb_keymap_key_repeats(*Keymap, u32) c_int;
extern fn xkb_compose_table_new_from_locale(*Context, [*:0]const u8, c_int) ?*ComposeTable;
extern fn xkb_compose_table_unref(?*ComposeTable) void;
extern fn xkb_compose_state_new(*ComposeTable, c_int) ?*Compose;
extern fn xkb_compose_state_unref(?*Compose) void;
extern fn xkb_compose_state_feed(*Compose, u32) c_int;
extern fn xkb_compose_state_get_status(*Compose) c_int;
extern fn xkb_compose_state_get_utf8(*Compose, [*]u8, usize) c_int;
extern fn xkb_compose_state_reset(*Compose) void;

// Same modifier positions as the existing shell controls; no GDK objects involved.
pub const shift = 1;
pub const control = 4;
pub const alt = 8;
pub const super = 1 << 26;
pub const Keyboard = struct {
    map: ?*Keymap = null,
    state: ?*State = null,
    compose: ?*Compose = null,
    pub fn deinit(self: *Keyboard) void {
        xkb_compose_state_unref(self.compose);
        xkb_state_unref(self.state);
        xkb_keymap_unref(self.map);
        self.* = .{};
    }
    pub fn load(self: *Keyboard, fd: c_int, format: u32, size: u32) void {
        defer _ = libc.close(fd);
        self.deinit();
        if (format != 1 or size == 0 or size > 16 * 1024 * 1024) return;
        const memory = libc.mmap(null, size, libc.PROT_READ, libc.MAP_SHARED, fd, 0);
        if (memory == null or memory == libc.MAP_FAILED) return;
        defer _ = libc.munmap(memory, size);
        const bytes: [*]const u8 = @ptrCast(memory);
        if (bytes[size - 1] != 0) return;
        const context = xkb_context_new(0) orelse return;
        defer xkb_context_unref(context);
        self.map = xkb_keymap_new_from_string(context, @ptrCast(bytes), 1, 0) orelse return;
        self.state = xkb_state_new(self.map.?);
        var locale: [*:0]const u8 = "C.UTF-8";
        for ([_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
            const value = libc.getenv(name);
            if (value != null and value[0] != 0) {
                locale = value;
                break;
            }
        }
        const table = xkb_compose_table_new_from_locale(context, locale, 0) orelse return;
        defer xkb_compose_table_unref(table);
        self.compose = xkb_compose_state_new(table, 0);
    }
    pub fn update(self: *Keyboard, depressed: u32, latched: u32, locked: u32, group: u32) void {
        if (self.state) |state| _ = xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
    }
    pub fn modifiers(self: *const Keyboard) u32 {
        const state = self.state orelse return 0;
        var result: u32 = 0;
        for ([_][*:0]const u8{ "Shift", "Control", "Mod1", "Mod4" }, [_]u32{ shift, control, alt, super }) |name, bit| {
            if (xkb_state_mod_name_is_active(state, name, 1 << 3) != 0) result |= bit;
        }
        return result;
    }
    pub fn symbol(self: *const Keyboard, code: u32) u32 {
        return if (self.state) |state| xkb_state_key_get_one_sym(state, code + 8) else 0;
    }
    pub fn repeats(self: *const Keyboard, code: u32) bool {
        return if (self.map) |map| xkb_keymap_key_repeats(map, code + 8) != 0 else false;
    }
    pub fn reset(self: *Keyboard) void {
        if (self.compose) |compose| xkb_compose_state_reset(compose);
    }
    /// Temporary UTF-8 storage belongs to the caller and can be securely erased
    /// after a password entry has consumed it.
    pub fn text(self: *Keyboard, code: u32, buffer: *[128]u8) []const u8 {
        const state = self.state orelse return "";
        if (self.modifiers() & (control | alt | super) != 0) return "";
        const key_symbol = self.symbol(code);
        var length: c_int = 0;
        if (self.compose) |compose| {
            _ = xkb_compose_state_feed(compose, key_symbol);
            switch (xkb_compose_state_get_status(compose)) {
                1 => return "", // A dead key or Compose sequence is in progress.
                2 => {
                    length = xkb_compose_state_get_utf8(compose, buffer, buffer.len);
                    self.reset();
                },
                3 => {
                    self.reset();
                    return "";
                },
                else => length = xkb_state_key_get_utf8(state, code + 8, buffer, buffer.len),
            }
        } else length = xkb_state_key_get_utf8(state, code + 8, buffer, buffer.len);
        if (length <= 0 or length >= buffer.len) return "";
        const value = buffer[0..@intCast(length)];
        if (std.mem.indexOfAny(u8, value, "\x00\r\n") != null) return "";
        for (value) |byte| if (byte < 32 or byte == 127) return "";
        return value;
    }
};

test "native XKB input follows modifiers, composes accents and suppresses control text" {
    const keymap: [:0]const u8 =
        \\xkb_keymap {
        \\ xkb_keycodes { include "evdev+aliases(qwerty)" };
        \\ xkb_types { include "complete" };
        \\ xkb_compatibility { include "complete" };
        \\ xkb_symbols { include "pc+us(intl)+inet(evdev)" };
        \\};
    ;
    const fd = libc.memfd_create("native-keyboard-test", libc.MFD_CLOEXEC);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(isize, @intCast(keymap.len + 1)), libc.write(fd, keymap.ptr, keymap.len + 1));
    var keyboard: Keyboard = .{};
    defer keyboard.deinit();
    keyboard.load(fd, 1, @intCast(keymap.len + 1));
    try std.testing.expect(keyboard.state != null);
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
    try std.testing.expect(keyboard.repeats(30));
    try std.testing.expect(!keyboard.repeats(42));
}

extern fn xkb_keysym_to_utf32(u32) u32;
pub fn unicode(symbol: u32) u32 {
    return xkb_keysym_to_utf32(symbol);
}
