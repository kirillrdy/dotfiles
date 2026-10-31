//! Cairo OSD rendering. GTK resolves the existing stylesheet without widgets.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const cast = c.__zig.cast;
pub const Kind = enum { volume, microphone, brightness };

fn context(provider: *c.GtkCssProvider, parent: ?*c.GtkStyleContext, kind: c.GType, name: [:0]const u8, id: ?[:0]const u8) *c.GtkStyleContext {
    const path = if (parent) |p| c.gtk_widget_path_copy(c.gtk_style_context_get_path(p)) else c.gtk_widget_path_new();
    defer c.gtk_widget_path_unref(path);
    const index = c.gtk_widget_path_append_type(path, kind);
    c.gtk_widget_path_iter_set_object_name(path, index, name);
    if (id) |value| c.gtk_widget_path_iter_set_name(path, index, value);
    const result = c.gtk_style_context_new();
    c.gtk_style_context_set_path(result, path);
    c.gtk_style_context_set_parent(result, parent);
    c.gtk_style_context_add_provider(result, cast(c.GtkStyleProvider, provider), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    return result;
}
fn integer(style: *c.GtkStyleContext, name: [:0]const u8, fallback: i32) i32 {
    var value: c.GValue = .{};
    c.gtk_style_context_get_property(style, name, 0, &value);
    defer c.g_value_unset(&value);
    const result = c.g_value_get_int(&value);
    return if (result > 0) std.math.clamp(result, 1, 4096) else fallback;
}

pub const Theme = struct {
    background: c.GdkRGBA = .{ .red = 46.0 / 255.0, .green = 46.0 / 255.0, .blue = 51.0 / 255.0, .alpha = 1 },
    foreground: c.GdkRGBA = .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 },
    track: c.GdkRGBA = .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.1 },
    fill: c.GdkRGBA = .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 },
    border_color: c.GdkRGBA = .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.02 },
    border: c.GtkBorder = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
    padding: c.GtkBorder = .{ .left = 18, .right = 18, .top = 12, .bottom = 12 },
    bar_margin: c.GtkBorder = .{ .right = 6 },
    bar_width: u32 = 160,
    bar_height: u32 = 6,

    pub fn load(path: [*:0]const u8) !Theme {
        const provider = c.gtk_css_provider_new().?;
        defer c.g_object_unref(provider);
        var err: [*c]c.GError = null;
        if (c.gtk_css_provider_load_from_path(provider, path, &err) == 0) {
            if (err != null) std.log.err("desktop-osd stylesheet: {s}", .{std.mem.span(err.*.message)});
            c.g_clear_error(&err);
            return error.InvalidStyle;
        }
        return fromProvider(provider);
    }
    fn fromProvider(provider: *c.GtkCssProvider) Theme {
        const window = context(provider, null, c.gtk_window_get_type(), "window", "osd");
        defer c.g_object_unref(window);
        const container = context(provider, window, c.gtk_box_get_type(), "box", "container");
        defer c.g_object_unref(container);
        const image = context(provider, container, c.gtk_image_get_type(), "image", null);
        defer c.g_object_unref(image);
        const bar = context(provider, container, c.gtk_progress_bar_get_type(), "progressbar", null);
        defer c.g_object_unref(bar);
        const trough = context(provider, bar, c.gtk_widget_get_type(), "trough", null);
        defer c.g_object_unref(trough);
        const progress = context(provider, trough, c.gtk_widget_get_type(), "progress", null);
        defer c.g_object_unref(progress);
        var result: Theme = .{};
        var color: c.GdkRGBA = .{};
        c.gtk_style_context_get_background_color(window, 0, &color);
        if (color.alpha > 0) result.background = color;
        c.gtk_style_context_get_color(image, 0, &result.foreground);
        c.gtk_style_context_get_background_color(trough, 0, &color);
        if (color.alpha > 0) result.track = color;
        c.gtk_style_context_get_background_color(progress, 0, &color);
        if (color.alpha > 0) result.fill = color;
        c.gtk_style_context_get_border_color(window, 0, &result.border_color);
        c.gtk_style_context_get_border(window, 0, &result.border);
        c.gtk_style_context_get_margin(container, 0, &result.padding);
        var padding: c.GtkBorder = .{};
        c.gtk_style_context_get_padding(container, 0, &padding);
        inline for (.{ "left", "right", "top", "bottom" }) |field| {
            @field(result.padding, field) = @intCast(std.math.clamp(@as(i32, @field(result.padding, field)) + @field(padding, field), 0, 256));
            @field(result.border, field) = std.math.clamp(@field(result.border, field), 0, 32);
        }
        c.gtk_style_context_get_margin(bar, 0, &result.bar_margin);
        inline for (.{ "left", "right", "top", "bottom" }) |field| @field(result.bar_margin, field) = std.math.clamp(@field(result.bar_margin, field), 0, 256);
        result.bar_width = @intCast(integer(bar, "min-width", 160));
        result.bar_height = @intCast(@max(integer(bar, "min-height", 6), integer(trough, "min-height", 6)));
        return result;
    }
    pub fn width(self: Theme) u32 {
        return @as(u32, @intCast(self.border.left + self.border.right + self.padding.left + self.padding.right + self.bar_margin.left + self.bar_margin.right)) + 24 + 12 + self.bar_width;
    }
    pub fn height(self: Theme) u32 {
        return @as(u32, @intCast(self.border.top + self.border.bottom + self.padding.top + self.padding.bottom)) + @max(24, self.bar_height + @as(u32, @intCast(self.bar_margin.top + self.bar_margin.bottom)));
    }
};

fn source(cr: *c.cairo_t, color: c.GdkRGBA, opacity: f64) void {
    c.cairo_set_source_rgba(cr, color.red, color.green, color.blue, color.alpha * opacity);
}
fn capsule(cr: *c.cairo_t, x: f64, y: f64, width: f64, height: f64) void {
    if (width <= 0 or height <= 0) return;
    const radius = @min(width, height) / 2;
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + width - radius, y + radius, radius, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, x + width - radius, y + height - radius, radius, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, x + radius, y + height - radius, radius, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, x + radius, y + radius, radius, std.math.pi, 3 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
    c.cairo_fill(cr);
}

pub fn paint(cr: *c.cairo_t, theme: Theme, kind: Kind, percent: f64, muted: bool, width: f64, height: f64) void {
    source(cr, theme.border_color, 1);
    capsule(cr, 0, 0, width, height);
    source(cr, theme.background, 1);
    capsule(cr, @floatFromInt(theme.border.left), @floatFromInt(theme.border.top), width - @as(f64, @floatFromInt(theme.border.left + theme.border.right)), height - @as(f64, @floatFromInt(theme.border.top + theme.border.bottom)));
    const opacity: f64 = if (muted) 0.5 else 1;
    const x: f64 = @floatFromInt(theme.border.left + theme.padding.left);
    const bar_x = x + 24 + 12 + @as(f64, @floatFromInt(theme.bar_margin.left));
    const bar_y = (height - @as(f64, @floatFromInt(theme.bar_height)) + @as(f64, @floatFromInt(theme.bar_margin.top - theme.bar_margin.bottom))) / 2;
    source(cr, theme.track, opacity);
    capsule(cr, bar_x, bar_y, @floatFromInt(theme.bar_width), @floatFromInt(theme.bar_height));
    source(cr, theme.fill, opacity);
    capsule(cr, bar_x, bar_y, @as(f64, @floatFromInt(theme.bar_width)) * std.math.clamp(percent, 0, 100) / 100, @floatFromInt(theme.bar_height));
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_translate(cr, x, (height - 24) / 2);
    source(cr, theme.foreground, opacity);
    icon(cr, kind, percent, muted);
}

fn icon(cr: *c.cairo_t, kind: Kind, percent: f64, muted: bool) void {
    c.cairo_set_line_width(cr, 2);
    c.cairo_set_line_cap(cr, 1); // Round symbolic strokes.
    switch (kind) {
        .brightness => {
            c.cairo_arc(cr, 12, 12, 4, 0, 2 * std.math.pi);
            c.cairo_fill(cr);
            for (0..8) |i| {
                const angle = @as(f64, @floatFromInt(i)) * std.math.pi / 4;
                c.cairo_move_to(cr, 12 + @cos(angle) * 7, 12 + @sin(angle) * 7);
                c.cairo_line_to(cr, 12 + @cos(angle) * 10, 12 + @sin(angle) * 10);
            }
            c.cairo_stroke(cr);
        },
        .microphone => {
            capsule(cr, 8, 2, 8, 12);
            c.cairo_arc(cr, 12, 10, 7, 0, std.math.pi);
            c.cairo_move_to(cr, 12, 17);
            c.cairo_line_to(cr, 12, 22);
            c.cairo_move_to(cr, 8, 22);
            c.cairo_line_to(cr, 16, 22);
            c.cairo_stroke(cr);
        },
        .volume => {
            c.cairo_move_to(cr, 3, 9);
            c.cairo_line_to(cr, 7, 9);
            c.cairo_line_to(cr, 12, 4);
            c.cairo_line_to(cr, 12, 20);
            c.cairo_line_to(cr, 7, 15);
            c.cairo_line_to(cr, 3, 15);
            c.cairo_close_path(cr);
            c.cairo_fill(cr);
            if (!muted and percent > 0) for ([_]f64{ 5, 8, 11 }, 0..) |radius, i| {
                if (i > 0 and percent < @as(f64, @floatFromInt(i)) * 33) break;
                c.cairo_new_sub_path(cr);
                c.cairo_arc(cr, 11, 12, radius, -std.math.pi / 3.0, std.math.pi / 3.0);
                c.cairo_stroke(cr);
            };
        },
    }
    if (muted) {
        c.cairo_move_to(cr, 3, 3);
        c.cairo_line_to(cr, 21, 21);
        c.cairo_stroke(cr);
    }
}

test "native OSD resolves existing CSS colors and dimensions without widgets" {
    try std.testing.expect(c.gtk_init_check(null, null) != 0);
    const provider = c.gtk_css_provider_new().?;
    defer c.g_object_unref(provider);
    const css =
        "window#osd { background: #2e2e33; color: white; border: 1px solid rgba(255,255,255,0.02); }" ++
        "window#osd #container { margin: 12px 18px; }" ++
        "window#osd progressbar { min-width: 160px; min-height: 6px; margin-right: 6px; }" ++
        "window#osd trough { background: rgba(255,255,255,0.1); min-height: 6px; }" ++
        "window#osd progress { background: white; }";
    try std.testing.expect(c.gtk_css_provider_load_from_data(provider, css, css.len, null) != 0);
    const theme = Theme.fromProvider(provider);
    try std.testing.expectEqual(@as(u32, 240), theme.width());
    try std.testing.expectEqual(@as(u32, 50), theme.height());
    try std.testing.expectApproxEqAbs(@as(f64, 46.0 / 255.0), theme.background.red, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), theme.track.alpha, 0.000001);
}

test "Cairo OSD has transparent corners, distinct progress, and muted feedback at both scales" {
    const theme: Theme = .{};
    for ([_]c_int{ 1, 2 }) |scale| {
        const width: c_int = @intCast(theme.width());
        const height: c_int = @intCast(theme.height());
        const image = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, width * scale, height * scale).?;
        defer c.cairo_surface_destroy(image);
        c.cairo_surface_set_device_scale(image, @floatFromInt(scale), @floatFromInt(scale));
        const cr = c.cairo_create(image).?;
        defer c.cairo_destroy(cr);
        for ([_]bool{ false, true }) |muted| {
            c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
            c.cairo_paint(cr);
            c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
            paint(cr, theme, .volume, 50, muted, @floatFromInt(width), @floatFromInt(height));
            c.cairo_surface_flush(image);
            const data: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(image)));
            const stride: usize = @intCast(@divTrunc(c.cairo_image_surface_get_stride(image), 4));
            const row: usize = @intCast(25 * scale);
            try std.testing.expectEqual(@as(u32, 0), data[0]);
            const filled = data[row * stride + @as(usize, @intCast(65 * scale))];
            const empty = data[row * stride + @as(usize, @intCast(195 * scale))];
            try std.testing.expect((filled & 255) > (empty & 255));
            if (!muted) try std.testing.expectEqual(@as(u32, 0xffffffff), filled) else try std.testing.expect((filled & 255) < 255);
        }
    }
}
