//! Notification cards drawn into native Wayland pixels. History keeps its GTK view.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const data = @import("desktop-notification-view.zig");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const a = std.heap.page_allocator;

pub const Theme = struct {
    background: raster.Color = .{ .red = 84.0 / 255.0, .green = 84.0 / 255.0, .blue = 90.0 / 255.0 },
    foreground: raster.Color = .{ .red = 1, .green = 1, .blue = 1 },
    secondary: raster.Color = .{ .red = 178.0 / 255.0, .green = 178.0 / 255.0, .blue = 180.0 / 255.0 },
    button: raster.Color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.15 },
    hover: raster.Color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.25 },
    pressed: raster.Color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.3 },

    pub fn load(provider: *c.GtkCssProvider) Theme {
        // Resolve the existing selectors without constructing any widgets.
        const root = context(provider, null, c.gtk_window_get_type(), "window", "notification-banner");
        defer c.g_object_unref(root);
        const card = context(provider, root, c.gtk_box_get_type(), "box", "desktop-notification");
        defer c.g_object_unref(card);
        const header = context(provider, card, c.gtk_box_get_type(), "box", "notification-header");
        defer c.g_object_unref(header);
        const button = context(provider, card, c.gtk_button_get_type(), "button", "notification-action");
        defer c.g_object_unref(button);
        var result: Theme = .{};
        var color: c.GdkRGBA = .{};
        c.gtk_style_context_get_background_color(card, 0, &color);
        if (color.alpha > 0) result.background = rgba(color);
        c.gtk_style_context_get_color(card, 0, &color);
        result.foreground = rgba(color);
        c.gtk_style_context_get_color(header, 0, &color);
        result.secondary = rgba(color);
        inline for (.{ "button", "hover", "pressed" }, .{ @as(c_uint, 0), c.GTK_STATE_FLAG_PRELIGHT, c.GTK_STATE_FLAG_ACTIVE }) |field, state| {
            c.gtk_style_context_get_background_color(button, state, &color);
            if (color.alpha > 0) @field(result, field) = rgba(color);
        }
        return result;
    }
};
fn rgba(color: c.GdkRGBA) raster.Color {
    return .{ .red = color.red, .green = color.green, .blue = color.blue, .alpha = color.alpha };
}
fn context(provider: *c.GtkCssProvider, parent: ?*c.GtkStyleContext, kind: c.GType, name: [:0]const u8, class: [:0]const u8) *c.GtkStyleContext {
    const path = if (parent) |p| c.gtk_widget_path_copy(c.gtk_style_context_get_path(p)) else c.gtk_widget_path_new();
    defer c.gtk_widget_path_unref(path);
    const index = c.gtk_widget_path_append_type(path, kind);
    c.gtk_widget_path_iter_set_object_name(path, index, name);
    c.gtk_widget_path_iter_add_class(path, index, class);
    const result = c.gtk_style_context_new();
    c.gtk_style_context_set_path(result, path);
    c.gtk_style_context_set_parent(result, parent);
    c.gtk_style_context_add_class(result, class);
    c.gtk_style_context_add_provider(result, @ptrCast(provider), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    return result;
}

pub const Target = enum { none, card, close, expand, action0, action1, action2 };
const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    fn contains(self: Rect, x: f64, y: f64) bool {
        return x >= self.x and y >= self.y and x < self.x + self.width and y < self.y + self.height;
    }
    fn shape(self: Rect, radius: f64) raster.Shape {
        return .{ .rounded_rect = .{ .rect = .{ .x = self.x, .y = self.y, .width = self.width, .height = self.height }, .radius = radius } };
    }
};

pub const View = struct {
    notice: data.Data,
    theme: Theme,
    width: u32 = 529,
    height: u32 = 118,
    expanded: bool = false,
    expandable: bool = false,
    hover: Target = .none,
    pressed: Target = .none,
    scale: u32 = 0,
    renderer: text.Renderer = .{},
    masks: [7]?text.Mask = @splat(null), // app, title, body, three actions, age
    icon: ?*c.GdkPixbuf = null,
    action_keys: [3]?[:0]const u8 = @splat(null),
    action_count: usize = 0,
    body_height: u32 = 19,

    pub fn init(notice: data.Data, theme: Theme, width: u32) View {
        var self: View = .{ .notice = notice, .theme = theme, .width = @max(160, width) };
        for (notice.actions) |action| {
            if (std.mem.eql(u8, action.key, "default") or self.action_count == 3) continue;
            self.action_keys[self.action_count] = action.key;
            self.action_count += 1;
        }
        return self;
    }
    pub fn deinit(self: *View) void {
        self.clear();
        self.renderer.deinit();
    }
    fn clear(self: *View) void {
        for (&self.masks) |*slot| {
            if (slot.*) |mask| mask.deinit(a);
            slot.* = null;
        }
        if (self.icon) |icon| c.g_object_unref(icon);
        self.icon = null;
        self.scale = 0;
    }
    fn closeRect(self: *const View) Rect {
        return .{ .x = @as(f64, @floatFromInt(self.width)) - 51, .y = 18, .width = 28, .height = 28 };
    }
    fn expandRect(self: *const View) Rect {
        var rect = self.closeRect();
        rect.x -= 34;
        return rect;
    }
    fn actionRect(self: *const View, index: usize) Rect {
        const count: f64 = @floatFromInt(self.action_count);
        const width = (@as(f64, @floatFromInt(self.width)) - 54 - (count - 1) * 8) / count;
        return .{ .x = 27 + @as(f64, @floatFromInt(index)) * (width + 8), .y = @as(f64, @floatFromInt(self.height)) - 51, .width = width, .height = 31 };
    }
    pub fn hit(self: *const View, x: f64, y: f64) Target {
        if (self.closeRect().contains(x, y)) return .close;
        if (self.expandable and self.expandRect().contains(x, y)) return .expand;
        if (self.expanded) for (0..self.action_count) |i| {
            if (self.actionRect(i).contains(x, y)) return @fromBackingInt(@intCast(@backingInt(Target.action0) + i));
        };
        const card: Rect = .{ .x = 8, .y = 8, .width = @floatFromInt(self.width - 16), .height = @floatFromInt(self.height - 16) };
        return if (card.contains(x, y)) .card else .none;
    }
    pub fn toggle(self: *View) void {
        if (!self.expandable) return;
        self.expanded = !self.expanded;
        self.clear();
    }
    fn label(self: *View, value: [:0]const u8, width: u32, bold: bool, body: bool, scale: u32) !text.Mask {
        return self.renderer.renderLayout(a, value, .{
            .font = if (bold) "Adwaita Sans Bold" else "Adwaita Sans",
            .size = 14.666 * @as(f64, @floatFromInt(scale)),
            .width = @max(1, width) * scale,
            .ellipsize = true,
            .origin = .top,
            .lines = if (body and self.expanded) 6 else 1,
            .markup = body,
        });
    }
    pub fn prepare(self: *View, scale: u32) !void {
        if (self.scale == scale) return;
        self.clear();
        errdefer self.clear();
        const content_width = self.width - 50 - @as(u32, if (self.notice.image != null) 60 else 0);
        self.masks[0] = try self.label(if (self.notice.app.len == 0) "Unknown App" else self.notice.app, self.width -| 250, true, false, scale);
        self.masks[1] = try self.label(self.notice.title, content_width, true, false, scale);
        self.masks[2] = try self.label(self.notice.body, content_width, false, true, scale);
        const age = @max(0, @divTrunc(c.g_get_real_time(), 1000000) - self.notice.created);
        var buffer: [64]u8 = undefined;
        const age_text: [:0]const u8 = if (age < 60) "Just now" else if (age < 3600) std.fmt.bufPrintSentinel(&buffer, "{d}m ago", .{@divTrunc(age, 60)}, 0) catch unreachable else std.fmt.bufPrintSentinel(&buffer, "{d}h ago", .{@divTrunc(age, 3600)}, 0) catch unreachable;
        self.masks[6] = try self.renderer.renderLayout(a, age_text, .{ .size = 12 * @as(f64, @floatFromInt(scale)), .width = 65 * scale, .ellipsize = true, .origin = .top });
        self.expandable = self.expanded or self.masks[2].?.ellipsized or self.action_count > 0;
        self.body_height = @max(19, std.math.divCeil(u32, self.masks[2].?.logical_height, scale) catch unreachable);
        self.height = 99 + @max(self.body_height, @as(u32, if (self.notice.image != null) 25 else 19)) + @as(u32, if (self.expanded and self.action_count > 0) 43 else 0);
        var i: usize = 0;
        for (self.notice.actions) |action| {
            if (std.mem.eql(u8, action.key, "default") or i == 3) continue;
            self.masks[3 + i] = try self.label(action.label, @intFromFloat(@max(1, self.actionRect(i).width - 24)), true, false, scale);
            i += 1;
        }
        const size: c_int = @intCast(16 * scale);
        if (c.g_path_is_absolute(self.notice.icon) != 0) {
            self.icon = c.gdk_pixbuf_new_from_file_at_scale(self.notice.icon, size, size, 1, null);
        } else if (c.gtk_icon_theme_lookup_icon(c.gtk_icon_theme_get_default(), self.notice.icon, size, c.GTK_ICON_LOOKUP_FORCE_SIZE)) |info| {
            defer c.g_object_unref(info);
            const foreground: c.GdkRGBA = .{ .red = self.theme.secondary.red, .green = self.theme.secondary.green, .blue = self.theme.secondary.blue, .alpha = self.theme.secondary.alpha };
            self.icon = c.gtk_icon_info_load_symbolic(info, &foreground, null, null, null, null, null);
        }
        self.scale = scale;
    }
    pub fn paint(self: *const View, buffer: raster.Buffer) void {
        const canvas: raster.Canvas = .{ .target = buffer, .scale = @floatFromInt(self.scale) };
        const card: Rect = .{ .x = 8, .y = 8, .width = @floatFromInt(self.width - 16), .height = @floatFromInt(self.height - 16) };
        // Layered translucent outlines approximate the existing soft shadow.
        for (0..4) |i| {
            const spread: f64 = @floatFromInt(4 - i);
            const shadow: Rect = .{ .x = card.x - spread, .y = card.y + 2 - spread, .width = card.width + spread * 2, .height = card.height + spread * 2 };
            canvas.draw(&.{shadow.shape(16 + spread)}, .{ .red = 0, .green = 0, .blue = 0, .alpha = 0.035 });
        }
        canvas.draw(&.{card.shape(16)}, self.theme.background);
        self.button(canvas, self.closeRect(), .close, 14);
        const close = self.closeRect();
        canvas.draw(&.{
            .{ .line = .{ .start = .{ .x = close.x + 10, .y = 28 }, .end = .{ .x = close.x + 18, .y = 36 }, .radius = 1 } },
            .{ .line = .{ .start = .{ .x = close.x + 18, .y = 28 }, .end = .{ .x = close.x + 10, .y = 36 }, .radius = 1 } },
        }, self.theme.foreground);
        if (self.expandable) {
            const rect = self.expandRect();
            self.button(canvas, rect, .expand, 14);
            const y: f64 = if (self.expanded) 34 else 30;
            const tip: f64 = if (self.expanded) 30 else 34;
            canvas.draw(&.{
                .{ .line = .{ .start = .{ .x = rect.x + 10, .y = y }, .end = .{ .x = rect.x + 14, .y = tip }, .radius = 1 } },
                .{ .line = .{ .start = .{ .x = rect.x + 14, .y = tip }, .end = .{ .x = rect.x + 18, .y = y }, .radius = 1 } },
            }, self.theme.foreground);
        }
        if (self.icon) |icon| image(canvas, icon, .{ .x = 21, .y = 24, .width = 16, .height = 16 });
        paintMask(canvas, self.masks[0], 43, 20, self.theme.secondary);
        paintMask(canvas, self.masks[6], @floatFromInt(self.width -| 170), 22, self.theme.secondary);
        const x: f64 = if (self.notice.image != null) 82 else 22;
        paintMask(canvas, self.masks[1], x, 55, self.theme.foreground);
        paintMask(canvas, self.masks[2], x, 78, self.theme.foreground);
        if (self.notice.image) |pixbuf| image(canvas, pixbuf, .{ .x = 22, .y = 55, .width = 48, .height = 48 });
        if (self.expanded) for (0..self.action_count) |i| {
            const rect = self.actionRect(i);
            self.button(canvas, rect, @fromBackingInt(@intCast(@backingInt(Target.action0) + i)), 8);
            const mask = self.masks[3 + i];
            const width: f64 = if (mask) |m| @as(f64, @floatFromInt(m.width)) / canvas.scale else 0;
            paintMask(canvas, mask, rect.x + (rect.width - width) / 2, rect.y + 6, self.theme.foreground);
        };
    }
    fn button(self: *const View, canvas: raster.Canvas, rect: Rect, target: Target, radius: f64) void {
        canvas.draw(&.{rect.shape(radius)}, if (self.pressed == target and self.hover == target) self.theme.pressed else if (self.hover == target) self.theme.hover else self.theme.button);
    }
};
fn paintMask(canvas: raster.Canvas, value: ?text.Mask, x: f64, y: f64, color: raster.Color) void {
    const mask = value orelse return;
    raster.mask(canvas.target, .{ .x = @as(i32, @intFromFloat(x * canvas.scale)) + mask.left, .y = @as(i32, @intFromFloat(y * canvas.scale)) + mask.top, .width = mask.width, .height = mask.height }, mask.pixels, color);
}

test "native banner colors resolve the existing stylesheet selectors and button states" {
    c.gtk_init(null, null);
    const provider = c.gtk_css_provider_new().?;
    defer c.g_object_unref(provider);
    try std.testing.expect(c.gtk_css_provider_load_from_data(provider,
        \\window.notification-banner .desktop-notification { background: #54545a; color: #fff; }
        \\.desktop-notification .notification-header { color: #b2b2b4; }
        \\.desktop-notification button { background: rgba(255,255,255,0.15); }
        \\.desktop-notification button:hover { background: rgba(255,255,255,0.25); }
        \\.desktop-notification button:active { background: rgba(255,255,255,0.3); }
    , -1, null) != 0);
    const theme = Theme.load(provider);
    try std.testing.expectApproxEqAbs(@as(f64, 84.0 / 255.0), theme.background.red, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 178.0 / 255.0), theme.secondary.red, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), theme.button.alpha, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), theme.hover.alpha, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), theme.pressed.alpha, 0.0001);
}
fn image(canvas: raster.Canvas, pixbuf: *c.GdkPixbuf, rect: Rect) void {
    const width: u32 = @intCast(c.gdk_pixbuf_get_width(pixbuf));
    const height: u32 = @intCast(c.gdk_pixbuf_get_height(pixbuf));
    const stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(pixbuf));
    const channels: u32 = @intCast(c.gdk_pixbuf_get_n_channels(pixbuf));
    const source: raster.Image = .{ .pixels = c.gdk_pixbuf_get_pixels(pixbuf)[0 .. (height - 1) * stride + width * channels], .width = width, .height = height, .stride = stride, .format = if (channels == 4) .rgba else .rgb };
    raster.blit(canvas.target, source, .{ .x = rect.x * canvas.scale, .y = rect.y * canvas.scale, .width = rect.width * canvas.scale, .height = rect.height * canvas.scale }, null) catch |err| std.log.warn("notification image: {s}", .{@errorName(err)});
}

test "native notification expansion wraps markup and keeps action hit regions inside the card at both scales" {
    c.gtk_init(null, null);
    const actions = [_]data.Action{ .{ .key = "default", .label = "Open" }, .{ .key = "reply", .label = "Reply" }, .{ .key = "archive", .label = "Archive" } };
    for ([_]u32{ 1, 2 }) |scale| {
        var card = View.init(.{ .id = 1, .app = "Messages", .title = "東京 — مرحبا", .body = "<b>A long notification</b> with wrapping text. This message includes enough words to occupy several lines when expanded. It should wrap naturally and preserve bold markup, while the collapsed card displays just one line. More text ensures the action row moves down with the expanded body.", .created = 0, .actions = &actions }, .{}, 529);
        defer card.deinit();
        try card.prepare(scale);
        const collapsed_height = card.height;
        try std.testing.expect(card.expandable);
        try std.testing.expect(card.masks[2].?.ellipsized);
        try std.testing.expectEqual(Target.close, card.hit(490, 30));
        try std.testing.expectEqual(Target.expand, card.hit(456, 30));
        try std.testing.expectEqual(Target.none, card.hit(0, 0));
        try std.testing.expectEqualStrings("reply", card.action_keys[0].?);
        card.toggle();
        try card.prepare(scale);
        try std.testing.expect(card.height > collapsed_height + 43);
        try std.testing.expect(card.body_height <= 6 * 24);
        const rect = card.actionRect(0);
        try std.testing.expectEqual(Target.action0, card.hit(rect.x + 10, rect.y + 10));
        const width = card.width * scale;
        const height = card.height * scale;
        const pixels = try std.testing.allocator.alloc(u32, width * height);
        defer std.testing.allocator.free(pixels);
        @memset(pixels, 0);
        card.paint(.{ .pixels = pixels, .width = width, .height = height });
        try std.testing.expectEqual(@as(u32, 0), pixels[0]);
        try std.testing.expectEqual(@as(u32, 0xff54545a), pixels[(height - 30 * scale) * width + 10 * scale]);
        card.toggle();
        try card.prepare(scale);
        try std.testing.expectEqual(collapsed_height, card.height);
    }
}
