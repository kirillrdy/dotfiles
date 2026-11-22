//! Lock-screen pixels modelled on GNOME Shell's unlock dialog: a blurred,
//! dimmed wallpaper with a clock, then an avatar and password prompt.
//! No credentials enter this view; it only sees a character count.
const std = @import("std");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const decode = @import("desktop-decode.zig");
const DateTime = @import("desktop-datetime.zig").DateTime;
const login = @import("desktop-login-ui.zig");

pub const Status = login.Status;
pub const Stage = enum { clock, prompt };

pub const Frame = struct {
    stage: Stage = .clock,
    status: Status = .ready,
    /// Characters shown as bullets; the password itself never reaches the view.
    typed: usize = 0,
    caps_lock: bool = false,
    /// Spinner rotation in radians while authenticating.
    spin: f64 = 0,
};

pub const Options = struct {
    wallpaper: ?[*:0]const u8 = null,
    avatar: ?[*:0]const u8 = null,
    name: []const u8,
};

// GNOME Shell unlockDialog.js dims the blurred wallpaper to BLUR_BRIGHTNESS.
const brightness = 0.65;
pub const fallback_background: u32 = 0xff1d1d20;
const warning = login.warning;

const avatar_size = 128;
const entry_width = login.entry_width;
const entry_height = login.entry_height;
const button_size = login.button_size;
const row_spacing = login.row_spacing;

const Label = enum { time, date, hint, name, placeholder, failed, caps };
const label_count = @typeInfo(Label).@"enum".field_names.len;

/// The geometry the client needs for pointer hit testing, in logical pixels.
pub const Layout = struct {
    back: raster.Rect,

    pub fn compute(width: f64, height: f64) Layout {
        const top = promptTop(height);
        const entry_y = top + avatar_size + 15 + 26 + 24;
        const left = (width - entry_width) / 2 - row_spacing - button_size;
        return .{ .back = .{ .x = left, .y = entry_y, .width = button_size, .height = button_size } };
    }
};

fn promptTop(height: f64) f64 {
    const block = avatar_size + 15 + 26 + 24 + entry_height + 12 + 20;
    return @max(0, @min(@floor(height / 3), height - block - 16));
}

pub const View = struct {
    allocator: std.mem.Allocator,
    renderer: text.Renderer = .{},
    backdrop: ?decode.Image = null,
    avatar: ?decode.Image = null,
    name: [:0]u8,
    time: [32:0]u8 = @splat(0),
    date: [96:0]u8 = @splat(0),
    masks: [label_count]?text.Mask = @splat(null),
    scale: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) !View {
        var self: View = .{ .allocator = allocator, .name = try allocator.dupeSentinel(u8, options.name, 0) };
        if (options.wallpaper) |path| {
            // A small decode is enough: the blur removes all detail anyway.
            if (decode.file(allocator, path, 256)) |image| {
                blur(image);
                self.backdrop = image;
            } else std.log.warn("lock: could not load wallpaper", .{});
        }
        if (options.avatar) |path| self.avatar = decode.file(allocator, path, avatar_size * 4);
        _ = self.tick();
        try self.prepare(1);
        return self;
    }

    pub fn deinit(self: *View) void {
        self.release();
        self.renderer.deinit();
        if (self.backdrop) |image| decode.free(self.allocator, image);
        if (self.avatar) |image| decode.free(self.allocator, image);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    fn release(self: *View) void {
        for (&self.masks) |*slot| {
            if (slot.*) |mask| mask.deinit(self.allocator);
            slot.* = null;
        }
    }

    /// Reformats the clock; returns whether the visible text changed.
    pub fn tick(self: *View) bool {
        const now = DateTime.now() catch return false;
        var changed = false;
        var scratch: [64]u8 = undefined;
        // GNOME's unlock dialog formats: 24-hour time and "%A %B %-d".
        for ([_]struct { buffer: []u8, format: [:0]const u8 }{ .{ .buffer = &self.time, .format = "%H:%M" }, .{ .buffer = &self.date, .format = "%A %B %-d" } }) |entry| {
            const formatted = now.format(&scratch, entry.format) catch continue;
            if (formatted.len >= entry.buffer.len) continue;
            if (std.mem.eql(u8, std.mem.sliceTo(entry.buffer, 0), formatted)) continue;
            @memset(entry.buffer, 0);
            @memcpy(entry.buffer[0..formatted.len], formatted);
            changed = true;
        }
        if (changed and self.scale != 0) {
            for ([_]Label{ .time, .date }) |label| {
                if (self.masks[@backingInt(label)]) |mask| mask.deinit(self.allocator);
                self.masks[@backingInt(label)] = null;
            }
            self.renderLabels(self.scale);
        }
        return changed;
    }

    fn prepare(self: *View, scale: u32) !void {
        if (self.scale == scale) return;
        self.release();
        self.scale = scale;
        self.renderLabels(scale);
    }

    fn renderLabels(self: *View, scale: u32) void {
        const factor: f64 = @floatFromInt(scale);
        for (&self.masks, 0..) |*slot, i| {
            if (slot.* != null) continue;
            const label: Label = @fromBackingInt(@intCast(i));
            const value: [:0]const u8 = switch (label) {
                .time => std.mem.sliceTo(&self.time, 0),
                .date => std.mem.sliceTo(&self.date, 0),
                .hint => "Click or press a key to unlock",
                .name => self.name,
                .placeholder => "Password",
                .failed => "Sorry, that didn’t work. Please try again.",
                .caps => "Caps lock is on.",
            };
            if (value.len == 0) continue;
            // Sizes follow gnome-shell's stylesheet: 64pt clock, 16pt date, 15pt title.
            const font: [:0]const u8, const size: f64 = switch (label) {
                .time => .{ "Adwaita Sans Light", 85.333 },
                .date => .{ "Adwaita Sans", 21.333 },
                .name => .{ "Adwaita Sans Extra-Bold", 20 },
                else => .{ "Adwaita Sans", 14.667 },
            };
            slot.* = self.renderer.renderLayout(self.allocator, value, .{ .font = font, .size = size * factor, .dpi = 96 * factor, .origin = .top }) catch |err| blk: {
                std.log.warn("lock: label: {s}", .{@errorName(err)});
                break :blk null;
            };
        }
    }

    /// Paints the blurred wallpaper. Callers cache the result per output size.
    pub fn background(self: *const View, target: raster.Buffer) void {
        const full: raster.Region = .{ .x = 0, .y = 0, .width = target.width, .height = target.height };
        if (self.backdrop) |image| {
            raster.cover(target, image.view()) catch raster.fill(target, full, fallback_background, .source);
        } else raster.fill(target, full, fallback_background, .source);
    }

    /// Paints the dialog over a buffer that already holds `background`.
    pub fn paint(self: *View, target: raster.Buffer, scale: u32, frame: Frame) void {
        self.prepare(scale) catch {};
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        const width = @as(f64, @floatFromInt(target.width)) / canvas.scale;
        const height = @as(f64, @floatFromInt(target.height)) / canvas.scale;
        switch (frame.stage) {
            .clock => self.paintClock(canvas, width, height),
            .prompt => self.paintPrompt(canvas, width, height, frame),
        }
    }

    fn labelMask(self: *const View, label: Label) ?text.Mask {
        return self.masks[@backingInt(label)];
    }

    /// Logical width and height of a label.
    fn extent(self: *const View, label: Label) [2]f64 {
        return login.maskExtent(self.labelMask(label), self.scale);
    }

    fn centered(self: *const View, canvas: raster.Canvas, label: Label, width: f64, y: f64, color: raster.Color) f64 {
        return login.paintCenteredMask(canvas, self.labelMask(label), self.scale, width, y, color);
    }

    fn paintClock(self: *const View, canvas: raster.Canvas, width: f64, height: f64) void {
        const white = raster.hex(0xffffff);
        const block = self.extent(.time)[1] + self.extent(.date)[1] + 48 + self.extent(.hint)[1];
        var y = @max(0, @min(@floor(height / 3), height - block - 16));
        y += self.centered(canvas, .time, width, y, white);
        y += self.centered(canvas, .date, width, y, white);
        _ = self.centered(canvas, .hint, width, y + 48, white);
    }

    fn paintPrompt(self: *const View, canvas: raster.Canvas, width: f64, height: f64, frame: Frame) void {
        const white = raster.hex(0xffffff);
        const busy = frame.status == .authenticating;
        const top = promptTop(height);
        login.paintAvatar(canvas, self.avatar, width / 2, top + avatar_size / 2, avatar_size);
        _ = self.centered(canvas, .name, width, top + avatar_size + 15, white);

        const layout = Layout.compute(width, height);
        const row_y = layout.back.y;
        const center_y = row_y + entry_height / 2;
        // Back button, as GNOME's circular cancel button returns to the clock.
        login.paintBackButton(canvas, layout.back, busy, false);

        // Pill-shaped entry with GNOME's focus ring.
        const entry: raster.Rect = .{ .x = @round((width - entry_width) / 2), .y = row_y, .width = entry_width, .height = entry_height };
        login.paintEntryFrame(canvas, entry, busy);
        login.paintPasswordDots(canvas, entry, frame.typed, busy, self.labelMask(.placeholder), self.scale);

        // The right well holds GNOME's spinner while PAM runs.
        if (busy) {
            login.paintSpinner(canvas, entry.x + entry_width + row_spacing + button_size / 2, center_y, frame.spin);
        }

        const message: ?Label = if (frame.status == .failed) .failed else if (frame.caps_lock) .caps else null;
        if (message) |label| _ = self.centered(canvas, label, width, row_y + entry_height + 12, raster.hex(warning));
    }
};

/// Three box-blur passes approximate a Gaussian; the result is dimmed like GNOME's.
fn blur(image: decode.Image) void {
    const pixels = std.mem.bytesAsSlice(u32, image.pixels);
    const stride = image.stride / 4;
    const radius: usize = @max(1, @max(image.width, image.height) / 48);
    var scratch: [4096]u32 = undefined;
    if (image.width > scratch.len or image.height > scratch.len) return;
    for (0..3) |_| {
        for (0..image.height) |y| boxPass(pixels[y * stride ..], 1, image.width, radius, &scratch);
        for (0..image.width) |x| boxPass(pixels[x..], stride, image.height, radius, &scratch);
    }
    for (0..image.height) |y| for (pixels[y * stride ..][0..image.width]) |*pixel| {
        var value = pixel.* & 0xff000000;
        for ([_]u5{ 16, 8, 0 }) |shift| {
            const channel: f64 = @floatFromInt((pixel.* >> shift) & 255);
            value |= @as(u32, @intFromFloat(@round(channel * brightness))) << shift;
        }
        pixel.* = value;
    };
}

/// One running-sum box filter along a row or column, clamping at the edges.
fn boxPass(line: []u32, step: usize, len: usize, radius: usize, scratch: []u32) void {
    for (0..len) |i| scratch[i] = line[i * step];
    const window: u32 = @intCast(2 * radius + 1);
    var sums: [4]u32 = @splat(0);
    const at = struct {
        fn f(values: []const u32, n: usize, index: isize) u32 {
            return values[@intCast(std.math.clamp(index, 0, @as(isize, @intCast(n - 1))))];
        }
    }.f;
    const r: isize = @intCast(radius);
    var k: isize = -r;
    while (k <= r) : (k += 1) {
        const value = at(scratch, len, k);
        for (&sums, 0..) |*sum, channel| sum.* += (value >> @intCast(channel * 8)) & 255;
    }
    for (0..len) |i| {
        var value: u32 = 0;
        for (sums, 0..) |sum, channel| value |= ((sum + window / 2) / window) << @intCast(channel * 8);
        line[i * step] = value;
        const index: isize = @intCast(i);
        const incoming = at(scratch, len, index + r + 1);
        const outgoing = at(scratch, len, index - r);
        for (&sums, 0..) |*sum, channel| sum.* = sum.* + ((incoming >> @intCast(channel * 8)) & 255) - ((outgoing >> @intCast(channel * 8)) & 255);
    }
}

test "blur keeps flat colours flat and dims them like GNOME" {
    const image = try decode.create(std.testing.allocator, 40, 30);
    defer decode.free(std.testing.allocator, image);
    @memset(std.mem.bytesAsSlice(u32, image.pixels), 0xff6496c8);
    blur(image);
    for (std.mem.bytesAsSlice(u32, image.pixels)) |pixel| try std.testing.expectEqual(@as(u32, 0xff416282), pixel);
}

test "blur spreads a bright point without overflowing channels" {
    const image = try decode.create(std.testing.allocator, 32, 32);
    defer decode.free(std.testing.allocator, image);
    const pixels = std.mem.bytesAsSlice(u32, image.pixels);
    @memset(pixels, 0xff000000);
    pixels[16 * 32 + 16] = 0xffffffff;
    blur(image);
    try std.testing.expect(pixels[16 * 32 + 16] & 0xff < 255);
    try std.testing.expect(pixels[16 * 32 + 15] & 0xff > 0);
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 255), pixel >> 24);
}

test "lock rendering is opaque in every stage and clips on small outputs" {
    const allocator = std.testing.allocator;
    var view = try View.init(allocator, .{ .name = "Test User" });
    defer view.deinit();
    for ([_][2]u32{ .{ 1280, 800 }, .{ 17, 13 } }) |size| for ([_]u32{ 1, 2 }) |scale| {
        const count = size[0] * size[1] * scale * scale;
        const storage = try allocator.alloc(u32, count + 2);
        defer allocator.free(storage);
        const target: raster.Buffer = .{ .pixels = storage[1 .. count + 1], .width = size[0] * scale, .height = size[1] * scale };
        for ([_]Stage{ .clock, .prompt }) |stage| for ([_]Status{ .ready, .authenticating, .failed }) |status| {
            @memset(storage, 0x12345678);
            view.background(target);
            view.paint(target, scale, .{ .stage = stage, .status = status, .typed = 5, .caps_lock = true, .spin = 1 });
            for (target.pixels) |pixel| try std.testing.expectEqual(@as(u32, 255), pixel >> 24);
            try std.testing.expectEqual(@as(u32, 0x12345678), storage[0]);
            try std.testing.expectEqual(@as(u32, 0x12345678), storage[count + 1]);
            if (size[0] > 100) {
                var foreground: usize = 0;
                for (target.pixels) |pixel| foreground += @intFromBool(pixel != fallback_background);
                try std.testing.expect(foreground > 100 * scale * scale);
                try std.testing.expectEqual(fallback_background, target.pixels[0]);
            }
        };
    };
}

test "prompt layout keeps the back button left of a centred entry" {
    const layout = Layout.compute(1280, 800);
    try std.testing.expectApproxEqAbs(@as(f64, 640 - entry_width / 2 - row_spacing - button_size), layout.back.x, 0.01);
    try std.testing.expect(layout.back.y > 800 / 3);
    try std.testing.expect(Layout.compute(320, 240).back.y >= 0);
}
