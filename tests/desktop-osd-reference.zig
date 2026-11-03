//! Cairo reference for the native OSD renderer, imported only by tests.
const std = @import("std");
const c = @import("../desktop-gtk.zig");
const view = @import("../desktop-osd-view.zig");
const Theme = view.Theme;
const Kind = view.Kind;

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
