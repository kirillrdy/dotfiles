//! Cairo geometry reference, used only to test the Zig selection renderer.
const c = @import("../desktop-gtk.zig");
const Rect = @import("../desktop-screenshot.zig").Rect;
pub fn paint(cr: *c.cairo_t, width: f64, height: f64, selected: ?Rect) void {
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0.35);
    c.cairo_paint(cr);
    const rect = selected orelse return;
    if (rect.w <= 1 or rect.h <= 1) return;
    const rx: f64 = @floatFromInt(rect.x);
    const ry: f64 = @floatFromInt(rect.y);
    const rw: f64 = @floatFromInt(rect.w);
    const rh: f64 = @floatFromInt(rect.h);
    c.cairo_save(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
    c.cairo_rectangle(cr, rx, ry, rw, rh);
    c.cairo_fill(cr);
    c.cairo_restore(cr);
    c.cairo_set_source_rgb(cr, 0.208, 0.518, 0.894);
    c.cairo_set_line_width(cr, 2);
    c.cairo_rectangle(cr, rx, ry, rw, rh);
    c.cairo_stroke(cr);
    const label_x = @max(0, @min(rx, width - 90));
    const label_y = @max(0, @min(ry + rh + 6, height - 22));
    c.cairo_set_source_rgba(cr, 0.1, 0.1, 0.1, 0.85);
    c.cairo_rectangle(cr, label_x, label_y, 90, 22);
    c.cairo_fill(cr);
}
