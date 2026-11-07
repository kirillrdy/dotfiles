//! Native notification cards shared by Wayland banners and date-menu history.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const a = std.heap.page_allocator;

pub const Action = struct { key: [:0]const u8, label: [:0]const u8 };
pub const Data = struct {
    id: u32,
    app: [:0]const u8,
    title: [:0]const u8,
    body: [:0]const u8,
    icon: [:0]const u8 = "application-x-executable-symbolic",
    image: ?*c.GdkPixbuf = null,
    actions: []const Action = &.{},
    created: i64,
};
const data = @This();

pub const Theme = struct {
    background: raster.Color = .{ .red = 84.0 / 255.0, .green = 84.0 / 255.0, .blue = 90.0 / 255.0 },
    foreground: raster.Color = .{ .red = 1, .green = 1, .blue = 1 },
    secondary: raster.Color = .{ .red = 178.0 / 255.0, .green = 178.0 / 255.0, .blue = 180.0 / 255.0 },
    button: raster.Color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.15 },
    hover: raster.Color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.25 },
    pressed: raster.Color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.3 },
};

pub const Target = enum { none, card, close, expand, action0, action1, action2 };
pub const Rect = raster.Rect;

pub const View = struct {
    notice: data.Data,
    theme: Theme,
    width: u32 = 529,
    height: u32 = 118,
    expanded: bool = false,
    history: bool = false,
    expandable: bool = false,
    hover: Target = .none,
    pressed: Target = .none,
    scale: u32 = 0,
    renderer: text.Renderer = .{},
    masks: [7]?text.Mask = @splat(null), // app, title, body, three actions, age
    shadow: ?[]u8 = null,
    icon: ?*c.GdkPixbuf = null,
    action_keys: [3]?[:0]const u8 = @splat(null),
    action_labels: [3]?[:0]const u8 = @splat(null),
    action_count: usize = 0,
    action_widths: [3]f64 = @splat(0),
    body_height: u32 = 19,
    age_x: f64 = 0,

    pub fn init(notice: data.Data, theme: Theme, width: u32) View {
        var self: View = .{ .notice = notice, .theme = theme, .width = @max(160, width) };
        for (notice.actions) |action| {
            if (std.mem.eql(u8, action.key, "default") or self.action_count == 3) continue;
            self.action_keys[self.action_count] = action.key;
            self.action_labels[self.action_count] = action.label;
            self.action_count += 1;
        }
        return self;
    }
    pub fn deinit(self: *View) void {
        self.clear();
        self.renderer.deinit();
    }
    pub fn invalidate(self: *View) void {
        self.clear();
    }
    fn clear(self: *View) void {
        if (self.shadow) |pixels| a.free(pixels);
        self.shadow = null;
        for (&self.masks) |*slot| {
            if (slot.*) |mask| mask.deinit(a);
            slot.* = null;
        }
        if (self.icon) |icon| c.g_object_unref(icon);
        self.icon = null;
        self.scale = 0;
    }
    fn closeRect(self: *const View) Rect {
        return .{ .x = @as(f64, @floatFromInt(self.width)) - 46, .y = 18, .width = 28, .height = 28 };
    }
    fn expandRect(self: *const View) Rect {
        var rect = self.closeRect();
        rect.x -= 34;
        return rect;
    }
    fn actionRect(self: *const View, index: usize) Rect {
        const count: f64 = @floatFromInt(self.action_count);
        const available = @as(f64, @floatFromInt(self.width)) - 38 - (count - 1) * 8;
        var natural: f64 = 0;
        for (self.action_widths[0..self.action_count]) |width| natural += width;
        const extra = @max(0, available - natural) / count;
        const ratio = if (natural > available) available / natural else 1;
        var x: f64 = 19;
        for (self.action_widths[0..index]) |width| x += width * ratio + extra + 8;
        return .{ .x = x, .y = @as(f64, @floatFromInt(self.height)) - 50, .width = self.action_widths[index] * ratio + extra, .height = 31 };
    }
    pub fn targetRect(self: *const View, target: Target) Rect {
        return switch (target) {
            .close => self.closeRect(),
            .expand => self.expandRect(),
            .action0, .action1, .action2 => self.actionRect(@backingInt(target) - @backingInt(Target.action0)),
            .card => .{ .x = 8, .y = 8, .width = @floatFromInt(self.width - 16), .height = @floatFromInt(self.height - 16) },
            .none => .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        };
    }
    pub fn targetVisible(self: *const View, target: Target) bool {
        return switch (target) {
            .none => false,
            .card, .close => true,
            .expand => self.expandable,
            .action0, .action1, .action2 => self.expanded and @backingInt(target) - @backingInt(Target.action0) < self.action_count,
        };
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
            .dpi = 96 * @as(f64, @floatFromInt(scale)),
            .line_height = 19 * scale,
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
        const content_width = self.width - 48 - @as(u32, if (self.notice.image != null) 60 else 0);
        self.masks[1] = try self.label(self.notice.title, content_width, true, false, scale);
        self.masks[2] = try self.label(self.notice.body, content_width, false, true, scale);
        const age = @max(0, @divTrunc(c.g_get_real_time(), 1000000) - self.notice.created);
        var buffer: [64]u8 = undefined;
        const age_text: [:0]const u8 = if (age < 60) "Just now" else if (age < 3600) std.fmt.bufPrintSentinel(&buffer, "{d}m ago", .{@divTrunc(age, 60)}, 0) catch unreachable else std.fmt.bufPrintSentinel(&buffer, "{d}h ago", .{@divTrunc(age, 3600)}, 0) catch unreachable;
        self.masks[6] = try self.renderer.renderLayout(a, age_text, .{ .size = 12 * @as(f64, @floatFromInt(scale)), .dpi = 96 * @as(f64, @floatFromInt(scale)), .width = 65 * scale, .ellipsize = true, .origin = .top });
        self.expandable = self.expanded or self.masks[2].?.ellipsized or self.action_count > 0;
        const age_width = std.math.divCeil(u32, self.masks[6].?.logical_width, scale) catch unreachable;
        const header_end: u32 = @intFromFloat((if (self.expandable) self.expandRect() else self.closeRect()).x - 9);
        self.masks[0] = try self.label(if (self.notice.app.len == 0) "Unknown App" else self.notice.app, header_end -| (43 + 6 + age_width), true, false, scale);
        self.age_x = 43 + @as(f64, @floatFromInt(self.masks[0].?.logical_width)) / @as(f64, @floatFromInt(scale)) + 6;
        self.body_height = @max(19, std.math.divCeil(u32, self.masks[2].?.logical_height, scale) catch unreachable);
        self.height = 99 + @max(self.body_height, @as(u32, if (self.notice.image != null) 25 else 19)) + @as(u32, if (self.expanded and self.action_count > 0) 39 else 0);
        var i: usize = 0;
        for (self.notice.actions) |action| {
            if (std.mem.eql(u8, action.key, "default") or i == 3) continue;
            self.masks[3 + i] = try self.label(action.label, self.width - 62, true, false, scale);
            self.action_widths[i] = @as(f64, @floatFromInt(self.masks[3 + i].?.logical_width)) / @as(f64, @floatFromInt(scale)) + 24;
            i += 1;
        }
        for (0..self.action_count) |index| {
            const limit: u32 = @intFromFloat(@max(1, self.actionRect(index).width - 24));
            if (self.masks[3 + index].?.logical_width > limit * scale) {
                self.masks[3 + index].?.deinit(a);
                self.masks[3 + index] = null;
                self.masks[3 + index] = try self.label(self.action_labels[index].?, limit, true, false, scale);
            }
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
        if (!self.history) self.shadow = try shadowMask(self.width, self.height, scale);
    }
    pub fn paint(self: *const View, buffer: raster.Buffer) void {
        const canvas: raster.Canvas = .{ .target = buffer, .scale = @floatFromInt(self.scale) };
        const card: Rect = .{ .x = 8, .y = 8, .width = @floatFromInt(self.width - 16), .height = @floatFromInt(self.height - 16) };
        // A released buffer can be repainted before the compositor acknowledges
        // an expanded size. Clip the new mask to that older destination.
        if (self.shadow) |pixels| raster.mask(buffer, .{ .x = 0, .y = 0, .width = self.width * self.scale, .height = self.height * self.scale }, pixels, .{ .red = 0, .green = 0, .blue = 0, .alpha = 0.2 });
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
        if (self.icon) |icon| c.__zig.blitPixbuf(canvas, icon, .{ .x = 21, .y = 24, .width = 16, .height = 16 });
        text.paintMask(canvas, self.masks[0], 43, 22, self.theme.secondary);
        text.paintMask(canvas, self.masks[6], self.age_x, 25, self.theme.secondary);
        const x: f64 = if (self.notice.image != null) 81 else 21;
        text.paintMask(canvas, self.masks[1], x, 55, self.theme.foreground);
        text.paintMask(canvas, self.masks[2], x, 78, self.theme.foreground);
        if (self.notice.image) |pixbuf| c.__zig.blitPixbuf(canvas, pixbuf, .{ .x = 21, .y = 55, .width = 48, .height = 48 });
        if (self.expanded) for (0..self.action_count) |i| {
            const rect = self.actionRect(i);
            self.button(canvas, rect, @fromBackingInt(@intCast(@backingInt(Target.action0) + i)), 8);
            const mask = self.masks[3 + i];
            const width: f64 = if (mask) |m| @as(f64, @floatFromInt(m.width)) / canvas.scale else 0;
            text.paintMask(canvas, mask, rect.x + (rect.width - width) / 2, rect.y + 6, self.theme.foreground);
        };
    }
    fn button(self: *const View, canvas: raster.Canvas, rect: Rect, target: Target, radius: f64) void {
        canvas.draw(&.{rect.shape(radius)}, if (self.pressed == target and self.hover == target) self.theme.pressed else if (self.hover == target) self.theme.hover else self.theme.button);
    }
};

// GNOME's 0 2px 4px 2px shadow: spread the rounded outline, then blur it.
// Cache the mask alongside text so pointer motion only composites pixels.
fn shadowMask(width: u32, height: u32, scale: u32) ![]u8 {
    const w = width * scale;
    const h = height * scale;
    const pixels = try a.alloc(u32, w * h);
    defer a.free(pixels);
    @memset(pixels, 0);
    const canvas: raster.Canvas = .{ .target = .{ .pixels = pixels, .width = w, .height = h }, .scale = @floatFromInt(scale) };
    const outline: Rect = .{ .x = 6, .y = 8, .width = @floatFromInt(width - 12), .height = @floatFromInt(height - 12) };
    canvas.draw(&.{outline.shape(18)}, .{ .red = 0, .green = 0, .blue = 0 });
    const horizontal = try a.alloc(f64, pixels.len);
    defer a.free(horizontal);
    const result = try a.alloc(u8, pixels.len);
    errdefer a.free(result);
    const radius: i32 = @intCast(6 * scale);
    const sigma: f64 = @floatFromInt(2 * scale);
    const kernel = try a.alloc(f64, @intCast(2 * radius + 1));
    defer a.free(kernel);
    var total: f64 = 0;
    for (kernel, 0..) |*weight, i| {
        const offset: f64 = @floatFromInt(@as(i32, @intCast(i)) - radius);
        weight.* = @exp(-offset * offset / (2 * sigma * sigma));
        total += weight.*;
    }
    for (kernel) |*weight| weight.* /= total;
    for (0..h) |y| for (0..w) |x| {
        var value: f64 = 0;
        for (kernel, 0..) |weight, i| {
            const source = @as(i64, @intCast(x)) + @as(i64, @intCast(i)) - radius;
            if (source >= 0 and source < w) value += weight * @as(f64, @floatFromInt(pixels[y * w + @as(usize, @intCast(source))] >> 24));
        }
        horizontal[y * w + x] = value;
    };
    for (0..h) |y| for (0..w) |x| {
        var value: f64 = 0;
        for (kernel, 0..) |weight, i| {
            const source = @as(i64, @intCast(y)) + @as(i64, @intCast(i)) - radius;
            if (source >= 0 and source < h) value += weight * horizontal[@as(usize, @intCast(source)) * w + x];
        }
        result[y * w + x] = @intFromFloat(@round(value));
    };
    return result;
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
        const old_height = collapsed_height * scale;
        const old_pixels = try std.testing.allocator.alloc(u32, width * old_height);
        defer std.testing.allocator.free(old_pixels);
        @memset(old_pixels, 0);
        card.paint(.{ .pixels = old_pixels, .width = width, .height = old_height });
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

test "GNOME header keeps the age beside the source and reserves button space" {
    c.gtk_init(null, null);
    for ([_]u32{ 1, 2 }) |scale| {
        var card = View.init(.{ .id = 1, .app = "Terminal", .title = "Build complete", .body = "All checks passed. Your desktop is ready.", .created = @divTrunc(c.g_get_real_time(), 1000000) }, .{}, 529);
        defer card.deinit();
        try card.prepare(scale);
        try std.testing.expectEqual(@as(u32, 118), card.height);
        try std.testing.expect(card.age_x > 100 and card.age_x < 125);
        try std.testing.expectEqual(@as(f64, 483), card.closeRect().x);
        // A long application name must ellipsize before reaching the controls.
        card.notice.app = "An application with an extremely long source name that must be ellipsized";
        card.scale = 0;
        try card.prepare(scale);
        try std.testing.expect(card.masks[0].?.ellipsized);
        const age_end = card.age_x + @as(f64, @floatFromInt(card.masks[6].?.logical_width)) / @as(f64, @floatFromInt(scale));
        try std.testing.expect(age_end <= card.closeRect().x - 9);
    }
}

test "expanded banner matches GNOME's measured line and action geometry" {
    c.gtk_init(null, null);
    const actions = [_]data.Action{ .{ .key = "open", .label = "Open Settings" }, .{ .key = "later", .label = "Later" } };
    for ([_]u32{ 1, 2 }) |scale| {
        var card = View.init(.{ .id = 1, .app = "Terminal", .title = "A longer notification title that should fit on one line", .body = "This notification contains a longer message that wraps onto multiple lines. Expand it to read the complete notification and choose an action.", .created = @divTrunc(c.g_get_real_time(), 1000000), .actions = &actions }, .{}, 529);
        defer card.deinit();
        try card.prepare(scale);
        card.toggle();
        try card.prepare(scale);
        try std.testing.expectEqual(@as(u32, 57), card.body_height);
        try std.testing.expectEqual(@as(u32, 195), card.height);
        const first = card.actionRect(0);
        const second = card.actionRect(1);
        try std.testing.expectEqual(@as(f64, 19), first.x);
        try std.testing.expectEqual(@as(f64, 145), first.y);
        try std.testing.expect(first.width > second.width);
        try std.testing.expectApproxEqAbs(@as(f64, 8), second.x - first.x - first.width, 0.001);
        try std.testing.expectApproxEqAbs(@as(f64, 510), second.x + second.width, 0.001);
    }
}
