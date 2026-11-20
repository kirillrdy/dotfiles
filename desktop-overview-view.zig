//! Activities compositing into native Wayland buffers, using the native canvas
//! for filtered image scaling and path rasterization in the animations.
const std = @import("std");
const draw = @import("desktop-canvas.zig");
const raster = @import("desktop-raster.zig");
const Image = @import("desktop-image.zig").Image;
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
    external_content: bool = false,
    caption: ?Caption = null,
    bounds_width: f64 = 0,
};

pub const close_button_radius: f64 = 16;
pub const icon_size: f64 = 64;
pub const icon_overlap: f64 = 0.7;
const window_active_size_inc: f64 = 5;

// Borrow the destination only for this draw. Native Wayland retains ownership
// of the shared-memory buffer; no GTK window or persistent drawing storage is used.
const Context = struct {
    cr: draw.Context,

    fn init(canvas: Canvas) ?Context {
        var cr = draw.Context.init(std.heap.c_allocator, .{ .pixels = canvas.target.pixels, .width = canvas.target.width, .height = canvas.target.height, .stride = canvas.target.width });
        cr.scale(canvas.scale, canvas.scale);
        cr.translate(canvas.origin.x, canvas.origin.y);
        return .{ .cr = cr };
    }
    fn deinit(self: *Context) void {
        self.cr.deinit();
    }
};

pub fn miniatureRounded(canvas: Canvas, source: ?raster.Image, rect: Rect, clip: Rect, radius: f64, animated: bool) void {
    var context = Context.init(canvas) orelse return;
    defer context.deinit();
    if (radius > 0) rounded(&context.cr, clip, radius) else context.cr.rectangle(clip.x, clip.y, clip.width, clip.height);
    context.cr.clip();
    drawImage(&context.cr, source, rect, 1, animated);
}

/// Cover the corners of GPU previews without repainting their content.
pub fn roundedMask(canvas: Canvas, rect: Rect, radius: f64) void {
    roundedMaskOptions(canvas, rect, radius, false);
}

pub fn roundedMaskShadow(canvas: Canvas, rect: Rect, radius: f64) void {
    roundedMaskOptions(canvas, rect, radius, true);
}

fn roundedMaskOptions(canvas: Canvas, rect: Rect, radius: f64, shadow: bool) void {
    var context = Context.init(canvas) orelse return;
    defer context.deinit();
    context.cr.rectangle(rect.x, rect.y, rect.width, rect.height);
    rounded(&context.cr, rect, radius);
    context.cr.setFillRule(.evenodd);
    context.cr.clip();
    context.cr.setSourceRgb(34.0 / 255.0, 34.0 / 255.0, 38.0 / 255.0);
    context.cr.paint();
    if (shadow) {
        context.cr.setFillRule(.nonzero);
        drawShadowRect(&context.cr, rect, radius, 4, 4, 16, 0.2);
    }
}

fn rounded(cr: *draw.Context, r: Rect, radius: f64) void {
    const rad = @max(0, @min(radius, @min(r.width, r.height) / 2));
    cr.newSubPath();
    cr.arc(r.x + r.width - rad, r.y + rad, rad, -std.math.pi / 2.0, 0);
    cr.arc(r.x + r.width - rad, r.y + r.height - rad, rad, 0, std.math.pi / 2.0);
    cr.arc(r.x + rad, r.y + r.height - rad, rad, std.math.pi / 2.0, std.math.pi);
    cr.arc(r.x + rad, r.y + rad, rad, std.math.pi, 1.5 * std.math.pi);
    cr.closePath();
}
fn drawImage(cr: *draw.Context, image: ?raster.Image, r: Rect, opacity: f64, animated: bool) void {
    cr.save();
    defer cr.restore();
    cr.translate(r.x, r.y);
    cr.rectangle(0, 0, r.width, r.height);
    cr.clip();
    if (image) |pixels| {
        std.debug.assert(pixels.format == .argb);
        // Borrow capture storage only for this draw.
        cr.scale(r.width / @as(f64, @floatFromInt(pixels.width)), r.height / @as(f64, @floatFromInt(pixels.height)));
        cr.setSourceImage(.fromRaster(pixels), 0, 0);
        cr.setExtend(.pad);
        if (animated) cr.setFilter(.bilinear);
        cr.paintWithAlpha(opacity);
    } else {
        cr.rectangle(0, 0, r.width, r.height);
        cr.setSourceRgb(0.3, 0.3, 0.33);
        cr.fill();
    }
}
fn drawShadowRect(cr: *draw.Context, r: Rect, corner_radius: f64, offset_y: f64, spread: f64, blur: f64, alpha: f64) void {
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
        cr.setSourceRgba(0, 0, 0, step_alpha);
        cr.fill();
    }
}

fn drawIconShadow(cr: *draw.Context, icon: Image, x: f64, y: f64, size: f64, offset_y: f64, alpha: f64) void {
    if (alpha <= 0) return;
    const iw = icon.width;
    const ih = icon.height;
    if (iw == 0 or ih == 0) return;
    const grid: usize = 64;
    const pad: usize = 6;
    const dim: usize = grid + 2 * pad;
    const radius: usize = 4;
    const sigma: f64 = 2.0;

    var buf_a: [dim * dim]f64 = @splat(0);
    var buf_b: [dim * dim]f64 = @splat(0);

    const pixels = std.mem.bytesAsSlice(u32, icon.pixels);
    const stride = icon.stride / 4;
    const fw: f64 = @floatFromInt(iw);
    const fh: f64 = @floatFromInt(ih);

    for (0..grid) |gy| {
        const sy_f = (@as(f64, @floatFromInt(gy)) + 0.5) * fh / @as(f64, @floatFromInt(grid)) - 0.5;
        const y0: usize = @intFromFloat(std.math.clamp(@floor(sy_f), 0, fh - 1));
        const y1: usize = @min(y0 + 1, ih - 1);
        const fy = std.math.clamp(sy_f - @as(f64, @floatFromInt(y0)), 0, 1);
        for (0..grid) |gx| {
            const sx_f = (@as(f64, @floatFromInt(gx)) + 0.5) * fw / @as(f64, @floatFromInt(grid)) - 0.5;
            const x0: usize = @intFromFloat(std.math.clamp(@floor(sx_f), 0, fw - 1));
            const x1: usize = @min(x0 + 1, iw - 1);
            const fx = std.math.clamp(sx_f - @as(f64, @floatFromInt(x0)), 0, 1);
            const sample = blk: {
                const p00: f64 = @floatFromInt(pixels[y0 * stride + x0] >> 24);
                const p10: f64 = @floatFromInt(pixels[y0 * stride + x1] >> 24);
                const p01: f64 = @floatFromInt(pixels[y1 * stride + x0] >> 24);
                const p11: f64 = @floatFromInt(pixels[y1 * stride + x1] >> 24);
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

    var shadow: [dim * dim]u32 = undefined;
    for (0..dim) |row| {
        for (0..dim) |col| {
            const byte: u32 = @intFromFloat(@round(std.math.clamp(buf_a[row * dim + col] * alpha, 0, 1) * 255.0));
            shadow[row * dim + col] = byte << 24;
        }
    }

    const icon_scale = size / @as(f64, @floatFromInt(grid));
    cr.save();
    defer cr.restore();
    cr.translate(x - @as(f64, @floatFromInt(pad)) * icon_scale, y + offset_y - @as(f64, @floatFromInt(pad)) * icon_scale);
    cr.scale(icon_scale, icon_scale);
    cr.setSourceImage(.{ .pixels = &shadow, .width = dim, .height = dim, .stride = dim }, 0, 0);
    cr.setFilter(.bilinear);
    cr.paint();
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

pub fn thumbnailIndicator(canvas: Canvas, thumbnail: Rect, opacity: f64) void {
    var context = Context.init(canvas) orelse return;
    defer context.deinit();
    const cr = &context.cr;
    rounded(cr, .{ .x = thumbnail.x - 1.5, .y = thumbnail.y - 1.5, .width = thumbnail.width + 3, .height = thumbnail.height + 3 }, 6.5);
    cr.setSourceRgba(0.208, 0.518, 0.894, opacity);
    cr.setLineWidth(3);
    cr.stroke();
}

pub fn workspace(canvas: Canvas, r: Rect, wallpaper: ?raster.Image, animated: bool) void {
    workspaceProgress(canvas, r, wallpaper, 1, animated);
}

pub fn workspaceProgress(canvas: Canvas, r: Rect, wallpaper: ?raster.Image, progress: f64, animated: bool) void {
    const clamped = std.math.clamp(progress, 0, 1);
    workspaceCard(canvas, r, wallpaper, 30 * clamped, clamped > 0, animated);
}

pub fn workspaceCard(canvas: Canvas, r: Rect, wallpaper: ?raster.Image, corner_radius: f64, shadow: bool, animated: bool) void {
    var context = Context.init(canvas) orelse return;
    defer context.deinit();
    const cr = &context.cr;
    if (shadow) drawShadowRect(cr, r, corner_radius, 4, 4, 16, 0.2);
    cr.save();
    defer cr.restore();
    rounded(cr, r, corner_radius);
    cr.clip();
    cr.setSourceRgb(0.015, 0.235, 0.53);
    cr.paint();
    if (wallpaper) |image| {
        const iw: f64 = @floatFromInt(image.width);
        const ih: f64 = @floatFromInt(image.height);
        const scale = @max(r.width / iw, r.height / ih);
        cr.translate(r.x + (r.width - iw * scale) / 2, r.y + (r.height - ih * scale) / 2);
        cr.scale(scale, scale);
        cr.setSourceImage(.fromRaster(image), 0, 0);
        cr.setExtend(.pad);
        if (animated) cr.setFilter(.bilinear);
        cr.paint();
    }
}

pub fn window(canvas: Canvas, r: Rect, captured: ?raster.Image, icon_image: ?Image, state: WindowState) void {
    const preview = previewRect(r, state.hovered, state.ease);
    {
        var context = Context.init(canvas) orelse return;
        defer context.deinit();
        const cr = &context.cr;
        // Captures already contain client decoration and corner transparency.
        if (!state.external_content) drawImage(cr, captured, preview, 1, state.animated);
        if (icon_image) |icon| {
            const icon_x = preview.x + preview.width / 2 - icon_size / 2;
            const icon_y = preview.y + preview.height - icon_size * icon_overlap;
            drawIconShadow(cr, icon, icon_x, icon_y, icon_size, 2, 0.4 * state.ease);
            drawImage(cr, icon.view(), .{ .x = icon_x, .y = icon_y, .width = icon_size, .height = icon_size }, state.ease, false);
        }
        if (state.hovered) {
            const close_r = closeButtonRect(preview);
            const close_cx = close_r.x + close_button_radius;
            const close_cy = close_r.y + close_button_radius;
            drawShadowRect(cr, close_r, close_button_radius, 2, 0, 4, 0.2 * state.ease);
            cr.arc(close_cx, close_cy, close_button_radius, 0, 2 * std.math.pi);
            if (state.close_pressed) {
                cr.setSourceRgba(94.0 / 255.0, 94.0 / 255.0, 105.0 / 255.0, 0.98 * state.ease);
            } else if (state.close_hovered) {
                cr.setSourceRgba(80.0 / 255.0, 80.0 / 255.0, 89.0 / 255.0, 0.98 * state.ease);
            } else {
                cr.setSourceRgba(63.0 / 255.0, 63.0 / 255.0, 70.0 / 255.0, 0.98 * state.ease);
            }
            cr.fill();
            cr.setSourceRgba(1, 1, 1, state.ease);
            cr.setLineWidth(2);
            cr.setLineCap(.round);
            cr.moveTo(close_cx - 5, close_cy - 5);
            cr.lineTo(close_cx + 5, close_cy + 5);
            cr.moveTo(close_cx + 5, close_cy - 5);
            cr.lineTo(close_cx - 5, close_cy + 5);
            cr.stroke();
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
