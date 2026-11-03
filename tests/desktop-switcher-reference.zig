//! Cairo reference for switcher panel geometry, imported only by tests.
const std = @import("std");
const c = @import("../desktop-gtk.zig");
fn rounded(cr: *c.cairo_t, x: f64, y: f64, width: f64, height: f64, requested_radius: f64) void {
    const radius = @min(requested_radius, @min(width, height) / 2);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + width - radius, y + radius, radius, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, x + width - radius, y + height - radius, radius, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, x + radius, y + height - radius, radius, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, x + radius, y + radius, radius, std.math.pi, 3 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}
pub fn panel(cr: *c.cairo_t, width: f64, height: f64) void {
    rounded(cr, 0.5, 0.5, width - 1, height - 1, 28);
    c.cairo_set_source_rgb(cr, 46.0 / 255.0, 46.0 / 255.0, 51.0 / 255.0);
    c.cairo_fill(cr);
    rounded(cr, 0.5, 0.5, width - 1, height - 1, 28);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.02);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
}
pub fn highlight(cr: *c.cairo_t, x: f64, width: f64, height: f64, active: bool, windows: bool) void {
    if (!active) return;
    rounded(cr, x, 13, width, height, 16);
    if (windows) c.cairo_set_source_rgb(cr, 65.0 / 255.0, 65.0 / 255.0, 73.0 / 255.0) else c.cairo_set_source_rgba(cr, 1, 1, 1, 0.2);
    c.cairo_fill(cr);
}
