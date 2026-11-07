//! Quick-settings layout, hit testing, and pixels. Services live in the controller.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const power = @import("desktop-power.zig");

pub const Target = enum {
    none,
    battery,
    screenshot,
    settings,
    lock,
    power,
    mute,
    volume,
    sound,
    brightness,
    wifi,
    network,
    profile_toggle,
    profiles,
    dark,
    dnd,
    profile0,
    profile1,
    profile2,
    power_settings,
    network0,
    network1,
    network2,
    network3,
    network4,
    network5,
    network6,
    network7,
    network_settings,
    suspend_action,
    reboot,
    poweroff,
    logout,
};
pub const Submenu = enum { none, network, profiles, power };
pub const Text = struct {
    bytes: [256:0]u8 = @splat(0),
    len: usize = 0,
    pub fn set(self: *Text, value: []const u8) void {
        self.len = @min(value.len, 256);
        while (!std.unicode.utf8ValidateSlice(value[0..self.len])) self.len -= 1;
        @memcpy(self.bytes[0..self.len], value[0..self.len]);
        self.bytes[self.len] = 0;
    }
    pub fn slice(self: *const Text) [:0]const u8 {
        return self.bytes[0..self.len :0];
    }
};
pub const Network = struct { title: Text = .{}, connected: bool = false, secure: bool = false, icon: [:0]const u8 = "network-wireless-symbolic" };
pub const Model = struct {
    volume: ?f64 = null,
    muted: bool = false,
    brightness: ?f64 = null,
    battery: Text = .{},
    battery_icon: Text = .{},
    wifi_enabled: bool = false,
    wifi_sensitive: bool = false,
    network_title: Text = .{},
    networks: [8]Network = @splat(.{}),
    network_count: usize = 0,
    power_state: power.State = .{},
    power_pending: bool = false,
    message: Text = .{},
    dark: bool = false,
    dark_sensitive: bool = false,
    dnd: bool = false,
    dnd_sensitive: bool = false,
    session_busy: bool = false,
};
pub const Rect = raster.Rect;
const Item = struct {
    target: Target,
    rect: Rect,
    title: [:0]const u8 = "",
    subtitle: [:0]const u8 = "",
    icon: [:0]const u8 = "",
    enabled: bool = true,
    active: bool = false,
    row: bool = false,
    check: bool = false,
    secure: bool = false,
};
const count = @typeInfo(Target).@"enum".field_names.len;
const Cached = struct {
    value: ?[:0]u8 = null,
    mask: ?text.Mask = null,
    width: u32 = 0,
    scale: u32 = 0,
    size: f64 = 0,
    bold: bool = false,
    fn clear(self: *Cached, allocator: std.mem.Allocator) void {
        if (self.value) |value| allocator.free(value);
        if (self.mask) |mask| mask.deinit(allocator);
        self.* = .{};
    }
    fn get(self: *Cached, allocator: std.mem.Allocator, renderer: *text.Renderer, value: [:0]const u8, width: u32, scale: u32, size: f64, bold: bool) !text.Mask {
        if (self.value == null or !std.mem.eql(u8, self.value.?, value) or self.width != width or self.scale != scale or self.size != size or self.bold != bold) {
            self.clear(allocator);
            errdefer self.clear(allocator);
            self.value = try allocator.dupeSentinel(u8, value, 0);
            self.mask = try renderer.renderLayout(allocator, value, .{ .font = if (bold) "Adwaita Sans Bold" else "Adwaita Sans", .size = size * @as(f64, @floatFromInt(scale)), .dpi = 96 * @as(f64, @floatFromInt(scale)), .width = width * scale, .ellipsize = true, .origin = .top });
            self.width = width;
            self.scale = scale;
            self.size = size;
            self.bold = bold;
        }
        return self.mask.?;
    }
};
const Icon = struct {
    name: ?[:0]u8 = null,
    pixels: ?[]u8 = null,
    scale: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    fn clear(self: *Icon, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.pixels) |pixels| allocator.free(pixels);
        self.* = .{};
    }
    fn prepare(self: *Icon, allocator: std.mem.Allocator, name: [:0]const u8, scale: u32) !void {
        if (self.name != null and std.mem.eql(u8, self.name.?, name) and self.scale == scale) return;
        self.clear(allocator);
        errdefer self.clear(allocator);
        self.name = try allocator.dupeSentinel(u8, name, 0);
        self.scale = scale;
        if (name.len == 0) return;
        const info = c.gtk_icon_theme_lookup_icon(c.gtk_icon_theme_get_default(), name, @intCast(16 * scale), c.GTK_ICON_LOOKUP_FORCE_SIZE) orelse return;
        defer c.g_object_unref(info);
        var white: c.GdkRGBA = .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 };
        const pixbuf = c.gtk_icon_info_load_symbolic(info, &white, null, null, null, null, null) orelse return;
        defer c.g_object_unref(pixbuf);
        self.pixels = try c.__zig.pixbufAlphaMask(allocator, pixbuf, &self.width, &self.height);
    }
};

pub const View = struct {
    model: Model = .{},
    submenu: Submenu = .none,
    width: u32 = 414,
    height: u32 = 0,
    items: [count]Item = undefined,
    item_count: usize = 0,
    hover: Target = .none,
    pressed: Target = .none,
    focus: Target = .none,
    keyboard_focus: bool = false,
    menu_rect: ?Rect = null,
    renderer: text.Renderer = .{},
    labels: [count][2]Cached = @splat(@splat(.{})),
    icons: [count]Icon = @splat(.{}),
    heading: Cached = .{},
    message: Cached = .{},

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        for (&self.labels) |*pair| for (pair) |*label| label.clear(allocator);
        for (&self.icons) |*icon| icon.clear(allocator);
        self.heading.clear(allocator);
        self.message.clear(allocator);
        self.renderer.deinit();
    }
    fn add(self: *View, entry: Item) void {
        self.items[self.item_count] = entry;
        self.item_count += 1;
    }
    pub fn item(self: *const View, target: Target) ?Item {
        for (self.items[0..self.item_count]) |entry| if (entry.target == target) return entry;
        return null;
    }
    pub fn enabled(self: *const View, target: Target) bool {
        return if (self.item(target)) |entry| entry.enabled else false;
    }
    pub fn hit(self: *const View, x: f64, y: f64) Target {
        for (self.items[0..self.item_count]) |entry| if (entry.enabled and entry.rect.contains(x, y)) return entry.target;
        return .none;
    }
    pub fn slider(target: Target) bool {
        return target == .volume or target == .brightness;
    }
    pub fn sliderValue(self: *const View, target: Target, x: f64) f64 {
        const rect = self.item(target).?.rect;
        return std.math.clamp((x - rect.x - 8) / (rect.width - 16) * 100, 0, 100);
    }
    pub fn stepFocus(self: *View, backward: bool) void {
        var start: usize = if (backward) 0 else self.item_count - 1;
        for (self.items[0..self.item_count], 0..) |entry, i| if (entry.target == self.focus) {
            start = i;
            break;
        };
        for (1..self.item_count + 1) |offset| {
            const index = if (backward) (start + self.item_count - offset) % self.item_count else (start + offset) % self.item_count;
            if (self.items[index].enabled) {
                self.focus = self.items[index].target;
                self.keyboard_focus = true;
                return;
            }
        }
        self.focus = .none;
    }
    pub fn layout(self: *View) void {
        self.item_count = 0;
        self.menu_rect = null;
        const m = &self.model;
        const right = @as(f64, @floatFromInt(self.width)) - 25;
        const content = right - 25;
        if (m.battery.len > 0) self.add(.{ .target = .battery, .rect = .{ .x = 25, .y = 25, .width = 110, .height = 38 }, .title = m.battery.slice(), .icon = m.battery_icon.slice() });
        for ([_]Target{ .screenshot, .settings, .lock, .power }, [_][:0]const u8{ "screenshooter-symbolic", "emblem-system-symbolic", "system-lock-screen-symbolic", "system-shutdown-symbolic" }, 0..) |target, icon, i| self.add(.{ .target = target, .rect = .{ .x = right - 188 + @as(f64, @floatFromInt(i)) * 50, .y = 25, .width = 38, .height = 38 }, .icon = icon, .active = target == .power and self.submenu == .power });
        var y: f64 = 75;
        if (self.submenu == .power) y = self.menu(y, content);
        if (m.volume != null) {
            self.add(.{ .target = .mute, .rect = .{ .x = 25, .y = y, .width = 28, .height = 28 }, .icon = if (m.muted or m.volume.? == 0) "audio-volume-muted-symbolic" else if (m.volume.? < 33) "audio-volume-low-symbolic" else if (m.volume.? < 66) "audio-volume-medium-symbolic" else "audio-volume-high-symbolic" });
            self.add(.{ .target = .volume, .rect = .{ .x = 59, .y = y, .width = content - 68, .height = 28 } });
            self.add(.{ .target = .sound, .rect = .{ .x = right - 28, .y = y, .width = 28, .height = 28 }, .icon = "go-next-symbolic" });
            y += 40;
        }
        if (m.brightness != null) {
            self.add(.{ .target = .brightness, .rect = .{ .x = 59, .y = y, .width = content - 34, .height = 28 } });
            y += 40;
        }
        const tile_width = (content - 12) / 2;
        const titles = [_][:0]const u8{ "Wi-Fi", "Power Mode" };
        const subtitles = [_][:0]const u8{ m.network_title.slice(), if (m.power_state.active) |profile| profile_names[@backingInt(profile)] else if (m.power_state.available[1]) "Custom" else "Unavailable" };
        for (0..2) |i| {
            const x = 25 + @as(f64, @floatFromInt(i)) * (tile_width + 12);
            const active = if (i == 0) m.wifi_enabled else m.power_state.active != null and m.power_state.active.? != .balanced;
            self.add(.{ .target = if (i == 0) .wifi else .profile_toggle, .rect = .{ .x = x, .y = y, .width = tile_width - 36, .height = 48 }, .title = titles[i], .subtitle = subtitles[i], .icon = if (i == 0) "network-wireless-symbolic" else if (m.power_state.active) |profile| profile_icons[@backingInt(profile)] else profile_icons[1], .enabled = if (i == 0) m.wifi_sensitive else !m.power_pending and m.power_state.available[1] and (m.power_state.active != .balanced or m.power_state.available[2]), .active = active });
            self.add(.{ .target = if (i == 0) .network else .profiles, .rect = .{ .x = x + tile_width - 36, .y = y, .width = 36, .height = 48 }, .icon = "go-next-symbolic", .active = active });
        }
        y += 60;
        if (self.submenu == .network or self.submenu == .profiles) y = self.menu(y, content);
        for ([_]Target{ .dark, .dnd }, [_][:0]const u8{ "Dark Style", "Do Not Disturb" }, [_][:0]const u8{ "dark-mode-symbolic", "notifications-disabled-symbolic" }, 0..) |target, title, icon, i| self.add(.{ .target = target, .rect = .{ .x = 25 + @as(f64, @floatFromInt(i)) * (tile_width + 12), .y = y, .width = tile_width, .height = 48 }, .title = title, .icon = icon, .enabled = if (i == 0) m.dark_sensitive else m.dnd_sensitive, .active = if (i == 0) m.dark else m.dnd });
        y += 48;
        if (m.message.len > 0) y += 31;
        self.height = @intFromFloat(y + 25);
        if (!self.enabled(self.hover)) self.hover = .none;
        if (!self.enabled(self.pressed)) self.pressed = .none;
        if (!self.enabled(self.focus)) self.focus = .none;
    }
    fn menu(self: *View, y: f64, width: f64) f64 {
        var row_y = y + 66;
        switch (self.submenu) {
            .profiles => {
                for (0..3) |i| if (self.model.power_state.available[i]) {
                    self.add(.{ .target = @fromBackingInt(@intCast(@backingInt(Target.profile0) + i)), .rect = .{ .x = 37, .y = row_y, .width = width - 24, .height = 36 }, .title = profile_names[i], .icon = profile_icons[i], .row = true, .check = if (self.model.power_state.active) |active| @backingInt(active) == i else false, .enabled = !self.model.power_pending });
                    row_y += 36;
                };
                self.add(.{ .target = .power_settings, .rect = .{ .x = 37, .y = row_y + 12, .width = width - 24, .height = 36 }, .title = "Power Settings", .row = true });
                row_y += 48;
            },
            .network => {
                for (self.model.networks[0..self.model.network_count], 0..) |*network, i| {
                    self.add(.{ .target = @fromBackingInt(@intCast(@backingInt(Target.network0) + i)), .rect = .{ .x = 37, .y = row_y, .width = width - 24, .height = 36 }, .title = network.title.slice(), .icon = network.icon, .row = true, .check = network.connected, .secure = network.secure, .enabled = self.model.wifi_enabled and self.model.wifi_sensitive });
                    row_y += 36;
                }
                self.add(.{ .target = .network_settings, .rect = .{ .x = 37, .y = row_y, .width = width - 24, .height = 36 }, .title = "Wi-Fi Settings", .row = true });
                row_y += 36;
            },
            .power => {
                for ([_]Target{ .suspend_action, .reboot, .poweroff, .logout }, [_][:0]const u8{ "Suspend", "Restart…", "Power Off…", "Log Out…" }) |target, title| {
                    self.add(.{ .target = target, .rect = .{ .x = 37, .y = row_y, .width = width - 24, .height = 36 }, .title = title, .row = true, .enabled = !self.model.session_busy });
                    row_y += 36;
                }
            },
            .none => unreachable,
        }
        self.menu_rect = .{ .x = 25, .y = y, .width = width, .height = row_y - y + 12 };
        return row_y + 24;
    }

    pub fn paint(self: *View, allocator: std.mem.Allocator, target: raster.Buffer, scale: u32) !void {
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        @memset(target.pixels, 0);
        const card: Rect = .{ .x = 6, .y = 6, .width = @floatFromInt(self.width - 12), .height = @floatFromInt(self.height - 12) };
        for (0..4) |i| {
            const spread: f64 = @floatFromInt(4 - i);
            const shadow: Rect = .{ .x = card.x - spread, .y = card.y + 2 - spread, .width = card.width + spread * 2, .height = card.height + spread * 2 };
            canvas.draw(&.{shadow.shape(36 + spread)}, rgb(0, 0.035));
        }
        canvas.draw(&.{card.shape(36)}, rgb(0x424247, 1));
        const inner: Rect = .{ .x = 7, .y = 7, .width = card.width - 2, .height = card.height - 2 };
        canvas.draw(&.{inner.shape(35)}, rgb(if (self.submenu == .none) 0x36363a else 0x202023, 1));
        if (self.menu_rect) |rect| {
            canvas.draw(&.{rect.shape(24)}, rgb(0x48484b, 1));
            const title: [:0]const u8 = switch (self.submenu) {
                .network => "Wi-Fi",
                .profiles => "Power Mode",
                .power => "Power Off",
                .none => unreachable,
            };
            const mask = try self.heading.get(allocator, &self.renderer, title, @intFromFloat(rect.width - 48), scale, 20, true);
            paintMask(canvas, mask, rect.x + 24, rect.y + 20, rgb(0xffffff, 1));
        }
        for (self.items[0..self.item_count]) |entry| {
            const index = @backingInt(entry.target);
            const dim = self.submenu != .none and !entry.row;
            const alpha: f64 = if (!entry.enabled) 0.5 else if (dim) 0.6 else 1;
            const foreground = rgb(0xffffff, alpha);
            const hovered = entry.enabled and self.hover == entry.target;
            const pressed = entry.enabled and self.pressed == entry.target and hovered;
            if (View.slider(entry.target)) {
                const level = if (entry.target == .volume) self.model.volume.? else self.model.brightness.?;
                const length = entry.rect.width - 16;
                const track: Rect = .{ .x = entry.rect.x + 8, .y = entry.rect.y + 12, .width = length, .height = 4 };
                canvas.draw(&.{track.shape(2)}, rgb(0xffffff, 0.1));
                var fill = track;
                fill.width *= std.math.clamp(level, 0, 100) / 100;
                if (fill.width > 0) canvas.draw(&.{fill.shape(2)}, rgb(0x3584e4, alpha));
                canvas.draw(&.{.{ .circle = .{ .center = .{ .x = track.x + fill.width, .y = track.y + 2 }, .radius = 8 } }}, rgb(0xe8e8e8, alpha));
                if (entry.target == .brightness) {
                    try self.icons[index].prepare(allocator, "display-brightness-symbolic", scale);
                    self.paintIcon(canvas, index, 31, entry.rect.y + 6, foreground);
                }
            } else {
                const plain = entry.row or entry.target == .mute or entry.target == .sound;
                if (!plain or hovered or pressed) {
                    const color: u32 = if (pressed) 0x5f5f63 else if (hovered) (if (entry.active) 0x4390e8 else 0x525256) else if (entry.active) 0x3584e4 else 0x48484b;
                    const cap: Cap = switch (entry.target) {
                        .wifi, .profile_toggle => .left,
                        .network, .profiles => .right,
                        else => .both,
                    };
                    paintButton(canvas, entry.rect, if (entry.row) 12 else entry.rect.height / 2, cap, rgb(color, if (plain) 0.7 else alpha));
                }
                try self.icons[index].prepare(allocator, entry.icon, scale);
                const icon_only = entry.title.len == 0;
                const icon_x = entry.rect.x + (if (icon_only) (entry.rect.width - 16) / 2 else @as(f64, 15));
                self.paintIcon(canvas, index, icon_x, entry.rect.y + (entry.rect.height - 16) / 2, foreground);
                if (!icon_only) {
                    const x = entry.rect.x + (if (entry.icon.len > 0) @as(f64, 40) else @as(f64, 12));
                    const width: u32 = @intFromFloat(@max(1, entry.rect.x + entry.rect.width - x - (if (entry.row) @as(f64, 42) else @as(f64, 9))));
                    const title = try self.labels[index][0].get(allocator, &self.renderer, entry.title, width, scale, 14.666, !entry.row);
                    const title_y = if (entry.subtitle.len > 0) entry.rect.y + 7 else entry.rect.y + (entry.rect.height - @as(f64, @floatFromInt(title.logical_height)) / canvas.scale) / 2;
                    paintMask(canvas, title, x, title_y, foreground);
                    if (entry.subtitle.len > 0) {
                        const subtitle = try self.labels[index][1].get(allocator, &self.renderer, entry.subtitle, width, scale, 12, false);
                        paintMask(canvas, subtitle, x, entry.rect.y + 26, foreground);
                    }
                    if (entry.check) {
                        const check = try self.labels[index][1].get(allocator, &self.renderer, "✓", 20, scale, 14.666, false);
                        paintMask(canvas, check, entry.rect.x + entry.rect.width - 26, entry.rect.y + 8, foreground);
                    }
                    if (entry.secure) {
                        const lock_x = entry.rect.x + entry.rect.width - 44;
                        const y = entry.rect.y + 13;
                        canvas.draw(&.{ .{ .rounded_stroke = .{ .rect = .{ .x = lock_x + 3, .y = y - 5, .width = 6, .height = 8 }, .radius = 3, .width = 1.5 } }, .{ .rounded_rect = .{ .rect = .{ .x = lock_x, .y = y, .width = 12, .height = 9 }, .radius = 2 } } }, foreground);
                    }
                }
            }
            if (entry.target == self.focus and self.keyboard_focus) canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = entry.rect.x + 2, .y = entry.rect.y + 2, .width = entry.rect.width - 4, .height = entry.rect.height - 4 }, .radius = 12, .width = 2 } }}, rgb(0x99c1f1, 0.8));
        }
        if (self.model.message.len > 0) {
            const mask = try self.message.get(allocator, &self.renderer, self.model.message.slice(), self.width - 50, scale, 12, false);
            paintMask(canvas, mask, 25, @as(f64, @floatFromInt(self.height)) - 44, rgb(0xffffff, 1));
        }
    }
    fn paintIcon(self: *const View, canvas: raster.Canvas, index: usize, x: f64, y: f64, color: raster.Color) void {
        const icon = self.icons[index];
        if (icon.pixels) |pixels| raster.mask(canvas.target, .{ .x = @intFromFloat(x * canvas.scale), .y = @intFromFloat(y * canvas.scale), .width = icon.width, .height = icon.height }, pixels, color);
    }
};
const Cap = enum { both, left, right };
fn paintButton(canvas: raster.Canvas, rect: Rect, radius: f64, cap: Cap, color: raster.Color) void {
    if (cap == .both) {
        canvas.draw(&.{rect.shape(radius)}, color);
        return;
    }
    // A split tile has a square seam and a semicircle only at its outer end.
    var points: [27]raster.Point = undefined;
    const edge = if (cap == .left) rect.x + rect.width else rect.x;
    points[0] = .{ .x = edge, .y = rect.y };
    points[1] = .{ .x = edge, .y = rect.y + rect.height };
    const center = if (cap == .left) rect.x + radius else rect.x + rect.width - radius;
    for (points[2..], 0..) |*point, i| {
        const angle = std.math.pi / 2.0 + @as(f64, @floatFromInt(i)) * std.math.pi / 24;
        point.* = .{ .x = center + (if (cap == .left) @cos(angle) else -@cos(angle)) * radius, .y = rect.y + radius + @sin(angle) * radius };
    }
    canvas.draw(&.{.{ .polygon = &points }}, color);
}
pub const profile_names = [_][:0]const u8{ "Performance", "Balanced", "Power Saver" };
pub const profile_icons = [_][:0]const u8{ "power-profile-performance-symbolic", "power-profile-balanced-symbolic", "power-profile-power-saver-symbolic" };
const rgb = raster.Color.rgb;
fn paintMask(canvas: raster.Canvas, mask: text.Mask, x: f64, y: f64, color: raster.Color) void {
    mask.paint(canvas, x, y, color);
}

test "quick-settings layout keeps hit regions separate and omits unavailable devices" {
    var view: View = .{};
    defer view.deinit(std.testing.allocator);
    view.layout();
    try std.testing.expect(view.item(.volume) == null and view.item(.brightness) == null and view.item(.battery) == null);
    try std.testing.expectEqual(Target.none, view.hit(40, 90)); // Disabled Wi-Fi.
    view.model.volume = 47;
    view.model.brightness = 30;
    view.model.battery.set("80%");
    view.model.wifi_sensitive = true;
    view.model.dark_sensitive = true;
    view.model.power_state = .{ .active = .balanced, .available = .{ false, true, true } };
    view.layout();
    const slider_rect = view.item(.volume).?.rect;
    try std.testing.expectEqual(@as(f64, 0), view.sliderValue(.volume, slider_rect.x - 100));
    try std.testing.expectEqual(@as(f64, 100), view.sliderValue(.volume, slider_rect.x + slider_rect.width + 100));
    try std.testing.expectApproxEqAbs(@as(f64, 50), view.sliderValue(.volume, slider_rect.x + slider_rect.width / 2), 0.001);
    for ([_]Submenu{ .none, .profiles, .network, .power }) |submenu| {
        view.submenu = submenu;
        view.layout();
        for (view.items[0..view.item_count], 0..) |entry, i| {
            try std.testing.expect(entry.rect.y + entry.rect.height < @as(f64, @floatFromInt(view.height)));
            if (entry.enabled) try std.testing.expectEqual(entry.target, view.hit(entry.rect.x + entry.rect.width / 2, entry.rect.y + entry.rect.height / 2));
            for (view.items[i + 1 .. view.item_count]) |other| try std.testing.expect(entry.rect.x + entry.rect.width <= other.rect.x or other.rect.x + other.rect.width <= entry.rect.x or entry.rect.y + entry.rect.height <= other.rect.y or other.rect.y + other.rect.height <= entry.rect.y);
        }
        if (submenu == .profiles) try std.testing.expect(view.item(.profile0) == null and view.item(.profile1) != null);
    }
    view.focus = .none;
    view.stepFocus(false);
    try std.testing.expectEqual(Target.battery, view.focus);
    view.stepFocus(true);
    try std.testing.expectEqual(Target.dark, view.focus); // DND is unavailable.
    view.pressed = .brightness;
    view.focus = .brightness;
    view.model.brightness = null;
    view.layout();
    try std.testing.expectEqual(Target.none, view.pressed);
    try std.testing.expectEqual(Target.none, view.focus);
}

test "quick-settings pixels support Unicode, menu states, scaling and clipped buffers" {
    c.gtk_init(null, null);
    const allocator = std.testing.allocator;
    var view: View = .{};
    defer view.deinit(allocator);
    view.model.volume = 63;
    view.model.brightness = 38;
    view.model.wifi_enabled = true;
    view.model.wifi_sensitive = true;
    view.model.dark_sensitive = true;
    view.model.dnd_sensitive = true;
    view.model.power_state = .{ .active = .balanced, .available = .{ true, true, true } };
    view.model.network_title.set("日本語 Wi-Fi");
    view.model.network_count = 8;
    for (&view.model.networks) |*network| {
        network.title.set("日本語のネットワーク — a long connection name");
        network.secure = true;
        network.connected = true;
    }
    for ([_]u32{ 1, 2 }) |scale| for ([_]Submenu{ .none, .network, .profiles, .power }) |submenu| {
        view.submenu = submenu;
        view.layout();
        const width = view.width * scale;
        const height = view.height * scale;
        const storage = try allocator.alloc(u32, width * height + 2);
        defer allocator.free(storage);
        @memset(storage, 0x12345678);
        try view.paint(allocator, .{ .pixels = storage[1 .. storage.len - 1], .width = width, .height = height }, scale);
        try std.testing.expectEqual(@as(u32, 0), storage[1]);
        try std.testing.expectEqual(@as(u32, 0x12345678), storage[0]);
        try std.testing.expectEqual(@as(u32, 0x12345678), storage[storage.len - 1]);
        // Pointer and focus changes reuse existing text/icon masks.
        view.hover = .dark;
        view.focus = .volume;
        view.keyboard_focus = true;
        var no_allocations = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        try view.paint(no_allocations.allocator(), .{ .pixels = storage[1 .. storage.len - 1], .width = width, .height = height }, scale);
        // A scrolled viewport can clip the canvas without touching other memory.
        try view.paint(allocator, .{ .pixels = storage[1..21], .width = 5, .height = 4 }, scale);
        try std.testing.expectEqual(@as(u32, 0x12345678), storage[0]);
        try std.testing.expectEqual(@as(u32, 0x12345678), storage[storage.len - 1]);
    };
}
