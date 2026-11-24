//! Activities compositing into native Wayland buffers, using desktop-raster
//! for filtered image scaling and antialiased shapes.
const std = @import("std");
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

fn physRect(canvas: Canvas, r: Rect) Rect {
    return .{
        .x = (r.x + canvas.origin.x) * canvas.scale,
        .y = (r.y + canvas.origin.y) * canvas.scale,
        .width = r.width * canvas.scale,
        .height = r.height * canvas.scale,
    };
}

fn physRegion(r: Rect) raster.Region {
    const x0: i32 = @intFromFloat(@floor(r.x));
    const y0: i32 = @intFromFloat(@floor(r.y));
    const x1: i32 = @intFromFloat(@ceil(r.x + r.width));
    const y1: i32 = @intFromFloat(@ceil(r.y + r.height));
    return .{ .x = x0, .y = y0, .width = @intCast(@max(0, x1 - x0)), .height = @intCast(@max(0, y1 - y0)) };
}

fn drawImage(canvas: Canvas, image: ?raster.Image, r: Rect, clip: ?Rect, clip_radius: f64, opacity: f64, animated: bool) void {
    if (opacity <= 0 or r.width <= 0 or r.height <= 0) return;
    const pr = physRect(canvas, r);
    const clip_rect = clip orelse r;
    const pc = physRect(canvas, clip_rect);
    if (image) |pixels| {
        std.debug.assert(pixels.format == .argb);
        raster.blitWithOptions(canvas.target, pixels, pr, .{
            .clip = physRegion(pc),
            .shape = if (clip_radius > 0) pc.shape(clip_radius * canvas.scale) else null,
            .opacity = opacity,
            .filter = if (animated) .bilinear else .good,
            .extend = .pad,
        }) catch {};
    } else {
        const gray: raster.Color = .{ .red = 0.3, .green = 0.3, .blue = 0.33, .alpha = opacity };
        const x0 = @max(r.x, clip_rect.x);
        const y0 = @max(r.y, clip_rect.y);
        const x1 = @min(r.x + r.width, clip_rect.x + clip_rect.width);
        const y1 = @min(r.y + r.height, clip_rect.y + clip_rect.height);
        if (x1 <= x0 or y1 <= y0) return;
        const inter: Rect = .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
        if (clip_radius <= 0) {
            canvas.draw(&.{inter.shape(0)}, gray);
        } else if (inter.x == clip_rect.x and inter.y == clip_rect.y and inter.width == clip_rect.width and inter.height == clip_rect.height) {
            canvas.draw(&.{clip_rect.shape(clip_radius)}, gray);
        } else {
            const rad = @max(0, @min(clip_radius, @min(clip_rect.width, clip_rect.height) / 2));
            const shape = clip_rect.shape(rad);
            const width_f: f64 = @floatFromInt(canvas.target.width);
            const height_f: f64 = @floatFromInt(canvas.target.height);
            const px0: usize = @intFromFloat(std.math.clamp(@floor((inter.x + canvas.origin.x) * canvas.scale - 1), 0, width_f));
            const py0: usize = @intFromFloat(std.math.clamp(@floor((inter.y + canvas.origin.y) * canvas.scale - 1), 0, height_f));
            const px1: usize = @intFromFloat(std.math.clamp(@ceil((inter.x + inter.width + canvas.origin.x) * canvas.scale + 1), 0, width_f));
            const py1: usize = @intFromFloat(std.math.clamp(@ceil((inter.y + inter.height + canvas.origin.y) * canvas.scale + 1), 0, height_f));
            const solid = raster.colorPixel(gray, 1);
            for (py0..py1) |y| {
                const py = (@as(f64, @floatFromInt(y)) + 0.5) / canvas.scale - canvas.origin.y;
                for (px0..px1) |x| {
                    const px = (@as(f64, @floatFromInt(x)) + 0.5) / canvas.scale - canvas.origin.x;
                    const d = @max(inter.shape(0).distance(.{ .x = px, .y = py }), shape.distance(.{ .x = px, .y = py }));
                    const cov = std.math.clamp(0.5 - d * canvas.scale, 0, 1);
                    if (cov == 0) continue;
                    const dest = &canvas.target.pixels[y * canvas.target.width + x];
                    dest.* = if (cov >= 1) (if (solid >> 24 == 255) solid else raster.over(dest.*, solid)) else raster.over(dest.*, raster.colorPixel(gray, cov));
                }
            }
        }
    }
}

pub fn miniatureRounded(canvas: Canvas, source: ?raster.Image, rect: Rect, clip: Rect, radius: f64, animated: bool) void {
    drawImage(canvas, source, rect, clip, radius, 1, animated);
}

/// Cover the corners of GPU previews without repainting their content.
/// Fades with the strip it masks; at full strength the corners would sit
/// over the zooming wallpaper while the overview animates in or out.
pub fn roundedMask(canvas: Canvas, rect: Rect, radius: f64, opacity: f64) void {
    roundedMaskOptions(canvas, rect, radius, false, opacity);
}

pub fn roundedMaskShadow(canvas: Canvas, rect: Rect, radius: f64) void {
    roundedMaskOptions(canvas, rect, radius, true, 1);
}

fn roundedMaskOptions(canvas: Canvas, rect: Rect, radius: f64, shadow: bool, opacity: f64) void {
    const rad = @max(0, @min(radius, @min(rect.width, rect.height) / 2));
    if (opacity <= 0 or rad <= 0 or rect.width <= 0 or rect.height <= 0) return;

    const bg: raster.Color = .{ .red = 34.0 / 255.0, .green = 34.0 / 255.0, .blue = 38.0 / 255.0, .alpha = opacity };
    const bg_solid = raster.colorPixel(bg, 1);
    const rect_shape = rect.shape(0);
    const round_shape = rect.shape(rad);

    // Precompute the 8 shadow steps if needed.
    const ShadowStep = struct { shape: raster.Shape, alpha: f64, solid: u32 };
    var shadow_steps: [8]ShadowStep = undefined;
    var shadow_count: usize = 0;
    if (shadow) {
        const steps: usize = 8;
        const offset_y: f64 = 4;
        const spread: f64 = 4;
        const blur: f64 = 16;
        const alpha: f64 = 0.2;
        const outer = spread + blur;
        const inner = spread - blur * 0.4;
        var cum: f64 = 0;
        for (0..steps) |step| {
            const t = @as(f64, @floatFromInt(step + 1)) / @as(f64, @floatFromInt(steps));
            const expand = outer + (inner - outer) * t;
            const target = alpha * (t * t * (3 - 2 * t));
            if (target <= cum or cum >= 0.999) continue;
            const step_alpha = std.math.clamp((target - cum) / (1 - cum), 0, 1);
            cum = target;
            const sr: Rect = .{
                .x = rect.x - expand,
                .y = rect.y + offset_y - expand,
                .width = rect.width + 2 * expand,
                .height = rect.height + 2 * expand,
            };
            if (sr.width <= 0 or sr.height <= 0) continue;
            shadow_steps[shadow_count] = .{
                .shape = sr.shape(@max(0, rad + expand)),
                .alpha = step_alpha,
                .solid = raster.colorPixel(.{ .red = 0, .green = 0, .blue = 0, .alpha = step_alpha }, 1),
            };
            shadow_count += 1;
        }
    }

    // Only the four corner squares can have nonzero (rect \ rounded_rect) coverage.
    const w_f: f64 = @floatFromInt(canvas.target.width);
    const h_f: f64 = @floatFromInt(canvas.target.height);
    const left_x0: usize = @intFromFloat(std.math.clamp(@floor((rect.x + canvas.origin.x) * canvas.scale - 1), 0, w_f));
    const left_x1: usize = @intFromFloat(std.math.clamp(@ceil((rect.x + rad + canvas.origin.x) * canvas.scale + 1), 0, w_f));
    const right_x0: usize = @max(left_x1, @as(usize, @intFromFloat(std.math.clamp(@floor((rect.x + rect.width - rad + canvas.origin.x) * canvas.scale - 1), 0, w_f))));
    const right_x1: usize = @intFromFloat(std.math.clamp(@ceil((rect.x + rect.width + canvas.origin.x) * canvas.scale + 1), 0, w_f));

    const top_y0: usize = @intFromFloat(std.math.clamp(@floor((rect.y + canvas.origin.y) * canvas.scale - 1), 0, h_f));
    const top_y1: usize = @intFromFloat(std.math.clamp(@ceil((rect.y + rad + canvas.origin.y) * canvas.scale + 1), 0, h_f));
    const bot_y0: usize = @max(top_y1, @as(usize, @intFromFloat(std.math.clamp(@floor((rect.y + rect.height - rad + canvas.origin.y) * canvas.scale - 1), 0, h_f))));
    const bot_y1: usize = @intFromFloat(std.math.clamp(@ceil((rect.y + rect.height + canvas.origin.y) * canvas.scale + 1), 0, h_f));

    const y_bands = [2][2]usize{ .{ top_y0, top_y1 }, .{ bot_y0, bot_y1 } };
    const x_bands = [2][2]usize{ .{ left_x0, left_x1 }, .{ right_x0, right_x1 } };

    for (y_bands) |yb| for (yb[0]..yb[1]) |y| {
        const py = (@as(f64, @floatFromInt(y)) + 0.5) / canvas.scale - canvas.origin.y;
        const row = canvas.target.pixels[y * canvas.target.width ..];
        for (x_bands) |xb| for (xb[0]..xb[1]) |x| {
            const px = (@as(f64, @floatFromInt(x)) + 0.5) / canvas.scale - canvas.origin.x;
            const p: raster.Point = .{ .x = px, .y = py };
            const rect_cov = std.math.clamp(0.5 - rect_shape.distance(p) * canvas.scale, 0, 1);
            if (rect_cov == 0) continue;
            const round_cov = std.math.clamp(0.5 - round_shape.distance(p) * canvas.scale, 0, 1);
            const mask_cov = @max(0, rect_cov - round_cov);
            if (mask_cov == 0) continue;
            row[x] = if (mask_cov >= 1)
                (if (bg_solid >> 24 == 255) bg_solid else raster.over(row[x], bg_solid))
            else
                raster.over(row[x], raster.colorPixel(bg, mask_cov));
            for (shadow_steps[0..shadow_count]) |step| {
                const s_cov = std.math.clamp(0.5 - step.shape.distance(p) * canvas.scale, 0, 1) * mask_cov;
                if (s_cov == 0) continue;
                row[x] = if (s_cov >= 1)
                    raster.over(row[x], step.solid)
                else
                    raster.over(row[x], raster.colorPixel(.{ .red = 0, .green = 0, .blue = 0, .alpha = step.alpha }, s_cov));
            }
        };
    };
}

fn drawShadowRect(canvas: Canvas, r: Rect, corner_radius: f64, offset_y: f64, spread: f64, blur: f64, alpha: f64, occlude_inner: bool) void {
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
        const shadow_color: raster.Color = .{ .red = 0, .green = 0, .blue = 0, .alpha = step_alpha };
        if (occlude_inner) {
            canvas.drawRoundedExcluded(sr, @max(0, corner_radius + expand), shadow_color, .{ .rect = r, .radius = corner_radius });
        } else {
            canvas.draw(&.{sr.shape(@max(0, corner_radius + expand))}, shadow_color);
        }
    }
}

fn drawIconShadow(canvas: Canvas, icon: Image, x: f64, y: f64, size: f64, offset_y: f64, alpha: f64) void {
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
    const dest = physRect(canvas, .{
        .x = x - @as(f64, @floatFromInt(pad)) * icon_scale,
        .y = y + offset_y - @as(f64, @floatFromInt(pad)) * icon_scale,
        .width = @as(f64, @floatFromInt(dim)) * icon_scale,
        .height = @as(f64, @floatFromInt(dim)) * icon_scale,
    });
    raster.blitWithOptions(canvas.target, .{
        .pixels = std.mem.sliceAsBytes(&shadow),
        .width = dim,
        .height = dim,
        .stride = dim * 4,
        .format = .argb,
    }, dest, .{ .filter = .bilinear, .extend = .none }) catch {};
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
    const r: Rect = .{ .x = thumbnail.x - 1.5, .y = thumbnail.y - 1.5, .width = thumbnail.width + 3, .height = thumbnail.height + 3 };
    canvas.draw(&.{r.stroke(6.5, 3)}, .{ .red = 0.208, .green = 0.518, .blue = 0.894, .alpha = opacity });
}

pub fn workspace(canvas: Canvas, r: Rect, wallpaper: ?raster.Image, animated: bool) void {
    workspaceProgress(canvas, r, wallpaper, 1, animated);
}

pub fn workspaceProgress(canvas: Canvas, r: Rect, wallpaper: ?raster.Image, progress: f64, animated: bool) void {
    const clamped = std.math.clamp(progress, 0, 1);
    workspaceCard(canvas, r, wallpaper, 30 * clamped, clamped > 0, animated);
}

pub fn workspaceCard(canvas: Canvas, r: Rect, wallpaper: ?raster.Image, corner_radius: f64, shadow: bool, animated: bool) void {
    if (shadow) drawShadowRect(canvas, r, corner_radius, 4, 4, 16, 0.2, true);
    canvas.draw(&.{r.shape(corner_radius)}, .{ .red = 0.015, .green = 0.235, .blue = 0.53 });
    if (wallpaper) |image| {
        const iw: f64 = @floatFromInt(image.width);
        const ih: f64 = @floatFromInt(image.height);
        const scale = @max(r.width / iw, r.height / ih);
        const wp_rect: Rect = .{
            .x = r.x + (r.width - iw * scale) / 2,
            .y = r.y + (r.height - ih * scale) / 2,
            .width = iw * scale,
            .height = ih * scale,
        };
        drawImage(canvas, image, wp_rect, r, corner_radius, 1, animated);
    }
}

pub fn window(canvas: Canvas, r: Rect, captured: ?raster.Image, icon_image: ?Image, state: WindowState) void {
    const preview = previewRect(r, state.hovered, state.ease);
    // Captures already contain client decoration and corner transparency.
    if (!state.external_content) drawImage(canvas, captured, preview, preview, 0, 1, state.animated);
    if (icon_image) |icon| {
        const icon_x = preview.x + preview.width / 2 - icon_size / 2;
        const icon_y = preview.y + preview.height - icon_size * icon_overlap;
        drawIconShadow(canvas, icon, icon_x, icon_y, icon_size, 2, 0.4 * state.ease);
        const icon_rect: Rect = .{ .x = icon_x, .y = icon_y, .width = icon_size, .height = icon_size };
        drawImage(canvas, icon.view(), icon_rect, icon_rect, 0, state.ease, false);
    }
    if (state.hovered) {
        const close_r = closeButtonRect(preview);
        const close_cx = close_r.x + close_button_radius;
        const close_cy = close_r.y + close_button_radius;
        drawShadowRect(canvas, close_r, close_button_radius, 2, 0, 4, 0.2 * state.ease, false);
        const fill_color: raster.Color = if (state.close_pressed)
            .{ .red = 94.0 / 255.0, .green = 94.0 / 255.0, .blue = 105.0 / 255.0, .alpha = 0.98 * state.ease }
        else if (state.close_hovered)
            .{ .red = 80.0 / 255.0, .green = 80.0 / 255.0, .blue = 89.0 / 255.0, .alpha = 0.98 * state.ease }
        else
            .{ .red = 63.0 / 255.0, .green = 63.0 / 255.0, .blue = 70.0 / 255.0, .alpha = 0.98 * state.ease };
        canvas.draw(&.{.{ .circle = .{ .center = .{ .x = close_cx, .y = close_cy }, .radius = close_button_radius } }}, fill_color);
        canvas.draw(&.{
            .{ .line = .{ .start = .{ .x = close_cx - 5, .y = close_cy - 5 }, .end = .{ .x = close_cx + 5, .y = close_cy + 5 }, .radius = 1 } },
            .{ .line = .{ .start = .{ .x = close_cx + 5, .y = close_cy - 5 }, .end = .{ .x = close_cx - 5, .y = close_cy + 5 }, .radius = 1 } },
        }, .{ .red = 1, .green = 1, .blue = 1, .alpha = state.ease });
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
