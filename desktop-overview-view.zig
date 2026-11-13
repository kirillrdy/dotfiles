//! Activities compositing into native Wayland buffers, using Cairo's optimized
//! filters and path rasterization for the opening and workspace animations.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const Rect = raster.Rect;
const Canvas = raster.Canvas;

pub const Caption = struct {
    mask: text.Mask,
    scale: u32,
};

pub const WindowState = struct {
    hovered: bool = false,
    close_hovered: bool = false,
    close_pressed: bool = false,
    ease: f64 = 1,
    animated: bool = false,
    caption: ?Caption = null,
    bounds_width: f64 = 0,
};

pub const close_button_radius: f64 = 16;
pub const icon_size: f64 = 64;
pub const icon_overlap: f64 = 0.7;
const window_active_size_inc: f64 = 5;

// Borrow the destination only for this draw. Native Wayland retains ownership
// of the shared-memory buffer; no GTK window or persistent Cairo storage is used.
const Context = struct {
    surface: *c.cairo_surface_t,
    cr: *c.cairo_t,

    fn init(canvas: Canvas) ?Context {
        const surface = c.cairo_image_surface_create_for_data(@ptrCast(canvas.target.pixels.ptr), c.CAIRO_FORMAT_ARGB32, @intCast(canvas.target.width), @intCast(canvas.target.height), @intCast(canvas.target.width * 4)) orelse return null;
        if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
            c.cairo_surface_destroy(surface);
            return null;
        }
        const cr = c.cairo_create(surface) orelse {
            c.cairo_surface_destroy(surface);
            return null;
        };
        c.cairo_scale(cr, canvas.scale, canvas.scale);
        c.cairo_translate(cr, canvas.origin.x, canvas.origin.y);
        return .{ .surface = surface, .cr = cr };
    }
    fn deinit(self: Context) void {
        c.cairo_destroy(self.cr);
        c.cairo_surface_flush(self.surface);
        c.cairo_surface_destroy(self.surface);
    }
};

pub fn miniature(canvas: Canvas, source: ?raster.Image, rect: Rect, clip: Rect, animated: bool) void {
    miniatureRounded(canvas, source, rect, clip, 0, animated);
}

pub fn miniatureRounded(canvas: Canvas, source: ?raster.Image, rect: Rect, clip: Rect, radius: f64, animated: bool) void {
    const context = Context.init(canvas) orelse return;
    defer context.deinit();
    if (radius > 0) rounded(context.cr, clip, radius) else c.cairo_rectangle(context.cr, clip.x, clip.y, clip.width, clip.height);
    c.cairo_clip(context.cr);
    drawImage(context.cr, source, rect, 1, animated);
}

fn rounded(cr: *c.cairo_t, r: Rect, radius: f64) void {
    const rad = @max(0, @min(radius, @min(r.width, r.height) / 2));
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, r.x + r.width - rad, r.y + rad, rad, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, r.x + r.width - rad, r.y + r.height - rad, rad, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, r.x + rad, r.y + r.height - rad, rad, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, r.x + rad, r.y + rad, rad, std.math.pi, 1.5 * std.math.pi);
    c.cairo_close_path(cr);
}
fn drawImage(cr: *c.cairo_t, image: ?raster.Image, r: Rect, opacity: f64, animated: bool) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_translate(cr, r.x, r.y);
    c.cairo_rectangle(cr, 0, 0, r.width, r.height);
    c.cairo_clip(cr);
    if (image) |pixels| {
        std.debug.assert(pixels.format == .argb);
        // Borrow capture storage only for this draw; no Cairo object owns it.
        const surface = c.cairo_image_surface_create_for_data(@constCast(pixels.pixels.ptr), c.CAIRO_FORMAT_ARGB32, @intCast(pixels.width), @intCast(pixels.height), @intCast(pixels.stride)) orelse return;
        defer c.cairo_surface_destroy(surface);
        if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) return;
        c.cairo_scale(cr, r.width / @as(f64, @floatFromInt(pixels.width)), r.height / @as(f64, @floatFromInt(pixels.height)));
        c.cairo_set_source_surface(cr, surface, 0, 0);
        c.cairo_pattern_set_extend(c.cairo_get_source(cr), c.CAIRO_EXTEND_PAD);
        if (animated) c.cairo_pattern_set_filter(c.cairo_get_source(cr), c.CAIRO_FILTER_BILINEAR);
        c.cairo_paint_with_alpha(cr, opacity);
    } else {
        c.cairo_rectangle(cr, 0, 0, r.width, r.height);
        c.cairo_set_source_rgb(cr, 0.3, 0.3, 0.33);
        c.cairo_fill(cr);
    }
}
fn drawShadowRect(cr: *c.cairo_t, r: Rect, corner_radius: f64, offset_y: f64, spread: f64, blur: f64, alpha: f64) void {
    if (alpha <= 0 or r.width <= 0 or r.height <= 0) return;
    const steps: usize = 8;
    const outer = spread + blur;
    const inner = spread - blur * 0.4;
    var cum: f64 = 0;
    for (0..steps) |step| {
        const t = @as(f64, @floatFromInt(step + 1)) / @as(f64, @floatFromInt(steps));
        const expand = outer + (inner - outer) * t;
        // Smoothstep cumulative profile matching CSS spread + blur decay.
        const target = alpha * (t * t * (3 - 2 * t));
        if (target <= cum or cum >= 0.999) continue;
        const step_alpha = std.math.clamp((target - cum) / (1 - cum), 0, 1);
        cum = target;
        const sr: Rect = .{
            .x = r.x - expand,
            .y = r.y + offset_y - expand,
            .width = r.width + 2 * expand,
            .height = r.height + 2 * expand,
        };
        if (sr.width <= 0 or sr.height <= 0) continue;
        rounded(cr, sr, @max(0, corner_radius + expand));
        c.cairo_set_source_rgba(cr, 0, 0, 0, step_alpha);
        c.cairo_fill(cr);
    }
}

fn drawIconShadow(cr: *c.cairo_t, icon: *c.GdkPixbuf, x: f64, y: f64, size: f64, offset_y: f64, alpha: f64) void {
    if (alpha <= 0) return;
    const iw = c.gdk_pixbuf_get_width(icon);
    const ih = c.gdk_pixbuf_get_height(icon);
    if (iw <= 0 or ih <= 0) return;
    const grid: usize = 64;
    const pad: usize = 6;
    const dim: usize = grid + 2 * pad;
    const radius: usize = 4;
    const sigma: f64 = 2.0;

    var buf_a: [dim * dim]f64 = @splat(0);
    var buf_b: [dim * dim]f64 = @splat(0);

    const has_alpha = c.gdk_pixbuf_get_has_alpha(icon) != 0;
    const channels: usize = @intCast(@max(1, c.gdk_pixbuf_get_n_channels(icon)));
    const stride: usize = @intCast(@max(0, c.gdk_pixbuf_get_rowstride(icon)));
    const pixels = c.gdk_pixbuf_get_pixels(icon);
    const fw: f64 = @floatFromInt(iw);
    const fh: f64 = @floatFromInt(ih);

    for (0..grid) |gy| {
        const sy_f = (@as(f64, @floatFromInt(gy)) + 0.5) * fh / @as(f64, @floatFromInt(grid)) - 0.5;
        const y0: usize = @intFromFloat(std.math.clamp(@floor(sy_f), 0, fh - 1));
        const y1: usize = @min(y0 + 1, @as(usize, @intCast(ih - 1)));
        const fy = std.math.clamp(sy_f - @as(f64, @floatFromInt(y0)), 0, 1);
        for (0..grid) |gx| {
            const sx_f = (@as(f64, @floatFromInt(gx)) + 0.5) * fw / @as(f64, @floatFromInt(grid)) - 0.5;
            const x0: usize = @intFromFloat(std.math.clamp(@floor(sx_f), 0, fw - 1));
            const x1: usize = @min(x0 + 1, @as(usize, @intCast(iw - 1)));
            const fx = std.math.clamp(sx_f - @as(f64, @floatFromInt(x0)), 0, 1);
            const sample = if (!has_alpha or channels < 4) @as(f64, 1) else blk: {
                const p00: f64 = @floatFromInt(pixels[y0 * stride + x0 * channels + 3]);
                const p10: f64 = @floatFromInt(pixels[y0 * stride + x1 * channels + 3]);
                const p01: f64 = @floatFromInt(pixels[y1 * stride + x0 * channels + 3]);
                const p11: f64 = @floatFromInt(pixels[y1 * stride + x1 * channels + 3]);
                const top = p00 + (p10 - p00) * fx;
                const bot = p01 + (p11 - p01) * fx;
                break :blk (top + (bot - top) * fy) / 255.0;
            };
            buf_a[(gy + pad) * dim + (gx + pad)] = sample;
        }
    }

    var kernel: [2 * radius + 1]f64 = undefined;
    var ksum: f64 = 0;
    for (&kernel, 0..) |*k, i| {
        const d: f64 = @floatFromInt(@as(isize, @intCast(i)) - @as(isize, @intCast(radius)));
        k.* = @exp(-(d * d) / (2 * sigma * sigma));
        ksum += k.*;
    }
    for (&kernel) |*k| k.* /= ksum;

    for (0..dim) |row| {
        for (0..dim) |col| {
            var acc: f64 = 0;
            for (kernel, 0..) |weight, ki| {
                const src_x: isize = @as(isize, @intCast(col)) + @as(isize, @intCast(ki)) - @as(isize, @intCast(radius));
                if (src_x >= 0 and src_x < dim) acc += weight * buf_a[row * dim + @as(usize, @intCast(src_x))];
            }
            buf_b[row * dim + col] = acc;
        }
    }
    for (0..dim) |row| {
        for (0..dim) |col| {
            var acc: f64 = 0;
            for (kernel, 0..) |weight, ki| {
                const src_y: isize = @as(isize, @intCast(row)) + @as(isize, @intCast(ki)) - @as(isize, @intCast(radius));
                if (src_y >= 0 and src_y < dim) acc += weight * buf_b[@as(usize, @intCast(src_y)) * dim + col];
            }
            buf_a[row * dim + col] = acc;
        }
    }

    const shadow_surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, dim, dim) orelse return;
    defer c.cairo_surface_destroy(shadow_surface);
    if (c.cairo_surface_status(shadow_surface) != c.CAIRO_STATUS_SUCCESS) return;
    const raw = c.cairo_image_surface_get_data(shadow_surface);
    const out_stride: usize = @intCast(c.cairo_image_surface_get_stride(shadow_surface));
    for (0..dim) |row| {
        const row_ptr: [*]u32 = @ptrCast(@alignCast(raw + row * out_stride));
        for (0..dim) |col| {
            const byte: u32 = @intFromFloat(@round(std.math.clamp(buf_a[row * dim + col] * alpha, 0, 1) * 255.0));
            row_ptr[col] = byte << 24;
        }
    }
    c.cairo_surface_mark_dirty(shadow_surface);

    const icon_scale = size / @as(f64, @floatFromInt(grid));
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_translate(cr, x - @as(f64, @floatFromInt(pad)) * icon_scale, y + offset_y - @as(f64, @floatFromInt(pad)) * icon_scale);
    c.cairo_scale(cr, icon_scale, icon_scale);
    c.cairo_set_source_surface(cr, shadow_surface, 0, 0);
    c.cairo_pattern_set_filter(c.cairo_get_source(cr), c.CAIRO_FILTER_BILINEAR);
    c.cairo_paint(cr);
}

pub fn pill(canvas: Canvas, rect: Rect) void {
    const radius = @min(rect.width, rect.height) / 2;
    canvas.draw(&.{.{ .rounded_rect = .{ .rect = rect, .radius = radius } }}, .{ .red = 0, .green = 0, .blue = 0, .alpha = 0.9 });
    if (rect.width > 1 and rect.height > 1) {
        canvas.draw(&.{.{ .rounded_stroke = .{
            .rect = .{ .x = rect.x + 0.5, .y = rect.y + 0.5, .width = rect.width - 1, .height = rect.height - 1 },
            .radius = @max(0, radius - 0.5),
            .width = 1,
        } }}, .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.1 });
    }
}

pub fn paintPillMask(canvas: Canvas, rect: Rect, mask: text.Mask, color: raster.Color) void {
    pill(canvas, rect);
    const px = @as(i32, @intFromFloat(@round((canvas.origin.x + rect.x + 13) * canvas.scale))) + mask.left;
    const py = @as(i32, @intFromFloat(@round((canvas.origin.y + rect.y + 7) * canvas.scale))) + mask.top;
    raster.mask(canvas.target, .{ .x = px, .y = py, .width = mask.width, .height = mask.height }, mask.pixels, color);
}

pub fn previewRect(r: Rect, hovered: bool, ease: f64) Rect {
    if (!hovered or r.width <= 0 or r.height <= 0) return r;
    const inc = window_active_size_inc * std.math.clamp(ease, 0, 1);
    const scale = @min((r.width + 2 * inc) / r.width, (r.height + 2 * inc) / r.height);
    const w = r.width * scale;
    const h = r.height * scale;
    return .{ .x = r.x - (w - r.width) / 2, .y = r.y - (h - r.height) / 2, .width = w, .height = h };
}

pub fn closeButtonRect(preview: Rect) Rect {
    return .{
        .x = preview.x + preview.width - close_button_radius,
        .y = preview.y - close_button_radius,
        .width = close_button_radius * 2,
        .height = close_button_radius * 2,
    };
}

pub fn thumbnailIndicator(canvas: Canvas, thumbnail: Rect) void {
    const context = Context.init(canvas) orelse return;
    defer context.deinit();
    const cr = context.cr;
    rounded(cr, .{ .x = thumbnail.x - 1.5, .y = thumbnail.y - 1.5, .width = thumbnail.width + 3, .height = thumbnail.height + 3 }, 6.5);
    c.cairo_set_source_rgb(cr, 0.208, 0.518, 0.894);
    c.cairo_set_line_width(cr, 3);
    c.cairo_stroke(cr);
}

pub fn workspace(canvas: Canvas, r: Rect, wallpaper: ?*c.cairo_surface_t, animated: bool) void {
    workspaceProgress(canvas, r, wallpaper, 1, animated);
}

pub fn workspaceProgress(canvas: Canvas, r: Rect, wallpaper: ?*c.cairo_surface_t, progress: f64, animated: bool) void {
    const clamped = std.math.clamp(progress, 0, 1);
    workspaceCard(canvas, r, wallpaper, 30 * clamped, clamped > 0, animated);
}

pub fn workspaceCard(canvas: Canvas, r: Rect, wallpaper: ?*c.cairo_surface_t, corner_radius: f64, shadow: bool, animated: bool) void {
    const context = Context.init(canvas) orelse return;
    defer context.deinit();
    const cr = context.cr;
    if (shadow) drawShadowRect(cr, r, corner_radius, 4, 4, 16, 0.2);
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    rounded(cr, r, corner_radius);
    c.cairo_clip(cr);
    c.cairo_set_source_rgb(cr, 0.015, 0.235, 0.53);
    c.cairo_paint(cr);
    if (wallpaper) |image| {
        const iw: f64 = @floatFromInt(c.cairo_image_surface_get_width(image));
        const ih: f64 = @floatFromInt(c.cairo_image_surface_get_height(image));
        const scale = @max(r.width / iw, r.height / ih);
        c.cairo_translate(cr, r.x + (r.width - iw * scale) / 2, r.y + (r.height - ih * scale) / 2);
        c.cairo_scale(cr, scale, scale);
        c.cairo_set_source_surface(cr, image, 0, 0);
        c.cairo_pattern_set_extend(c.cairo_get_source(cr), c.CAIRO_EXTEND_PAD);
        if (animated) c.cairo_pattern_set_filter(c.cairo_get_source(cr), c.CAIRO_FILTER_BILINEAR);
        c.cairo_paint(cr);
    }
}

pub fn window(canvas: Canvas, r: Rect, captured: ?raster.Image, icon_image: ?*c.GdkPixbuf, state: WindowState) void {
    const preview = previewRect(r, state.hovered, state.ease);
    {
        const context = Context.init(canvas) orelse return;
        defer context.deinit();
        const cr = context.cr;
        // Captures already contain client decoration and corner transparency.
        drawImage(cr, captured, preview, 1, state.animated);
        if (icon_image) |icon| {
            const icon_x = preview.x + preview.width / 2 - icon_size / 2;
            const icon_y = preview.y + preview.height - icon_size * icon_overlap;
            drawIconShadow(cr, icon, icon_x, icon_y, icon_size, 2, 0.4 * state.ease);
            c.cairo_save(cr);
            c.cairo_translate(cr, icon_x, icon_y);
            c.cairo_scale(cr, icon_size / @as(f64, @floatFromInt(c.gdk_pixbuf_get_width(icon))), icon_size / @as(f64, @floatFromInt(c.gdk_pixbuf_get_height(icon))));
            c.gdk_cairo_set_source_pixbuf(cr, icon, 0, 0);
            c.cairo_paint_with_alpha(cr, state.ease);
            c.cairo_restore(cr);
        }
        if (state.hovered) {
            const close_r = closeButtonRect(preview);
            const close_cx = close_r.x + close_button_radius;
            const close_cy = close_r.y + close_button_radius;
            drawShadowRect(cr, close_r, close_button_radius, 2, 0, 4, 0.2 * state.ease);
            c.cairo_arc(cr, close_cx, close_cy, close_button_radius, 0, 2 * std.math.pi);
            if (state.close_pressed) {
                c.cairo_set_source_rgba(cr, 94.0 / 255.0, 94.0 / 255.0, 105.0 / 255.0, 0.98 * state.ease);
            } else if (state.close_hovered) {
                c.cairo_set_source_rgba(cr, 80.0 / 255.0, 80.0 / 255.0, 89.0 / 255.0, 0.98 * state.ease);
            } else {
                c.cairo_set_source_rgba(cr, 63.0 / 255.0, 63.0 / 255.0, 70.0 / 255.0, 0.98 * state.ease);
            }
            c.cairo_fill(cr);
            c.cairo_set_source_rgba(cr, 1, 1, 1, state.ease);
            c.cairo_set_line_width(cr, 2);
            c.cairo_set_line_cap(cr, 1);
            c.cairo_move_to(cr, close_cx - 5, close_cy - 5);
            c.cairo_line_to(cr, close_cx + 5, close_cy + 5);
            c.cairo_move_to(cr, close_cx + 5, close_cy - 5);
            c.cairo_line_to(cr, close_cx - 5, close_cy + 5);
            c.cairo_stroke(cr);
        }
    }
    if (state.hovered and state.ease > 0.01) if (state.caption) |caption| {
        const factor: f64 = @floatFromInt(@max(1, caption.scale));
        const pill_w = @as(f64, @floatFromInt(caption.mask.logical_width)) / factor + 26;
        const pill_h = @as(f64, @floatFromInt(caption.mask.logical_height)) / factor + 14;
        const icon_bottom = if (icon_image != null)
            preview.y + preview.height - icon_size * icon_overlap + icon_size
        else
            preview.y + preview.height;
        var cap_x = preview.x + preview.width / 2 - pill_w / 2;
        if (state.bounds_width > pill_w + 16) cap_x = std.math.clamp(cap_x, 8, state.bounds_width - pill_w - 8);
        const cap_rect: Rect = .{ .x = cap_x, .y = icon_bottom + 6, .width = pill_w, .height = pill_h };
        paintPillMask(canvas, cap_rect, caption.mask, .{ .red = 1, .green = 1, .blue = 1, .alpha = state.ease });
    };
}
