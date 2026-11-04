//! Public askpass labels and native geometry. Passwords are drawn by the entry.
const std = @import("std");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
pub const Mode = enum {
    password,
    confirm,
    information,
    pub fn fromHint(hint: ?[]const u8) Mode {
        if (hint) |value| {
            if (std.mem.eql(u8, value, "confirm")) return .confirm;
            if (std.mem.eql(u8, value, "none")) return .information;
        }
        return .password;
    }
};
pub const Target = enum { none, entry, cancel, accept };
pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    pub fn contains(self: Rect, x: f64, y: f64) bool {
        return x >= self.x and y >= self.y and x < self.x + self.width and y < self.y + self.height;
    }
    fn shape(self: Rect, radius: f64) raster.Shape {
        return .{ .rounded_rect = .{ .rect = .{ .x = self.x, .y = self.y, .width = self.width, .height = self.height }, .radius = radius } };
    }
};
const Part = struct { mask: text.Mask, y: u32 };
pub const View = struct {
    mode: Mode,
    width: u32 = 460,
    height: u32 = 0,
    prompt_height: u32 = 0,
    scale: u32 = 0,
    focus: Target,
    keyboard_focus: bool = true,
    hover: Target = .none,
    pressed: Target = .none,
    renderer: text.Renderer = .{},
    masks: [3]?text.Mask = @splat(null),
    parts: std.ArrayList(Part) = .empty,

    pub fn init(mode: Mode) View {
        return .{ .mode = mode, .focus = switch (mode) {
            .password => .entry,
            .confirm => .cancel,
            .information => .accept,
        } };
    }
    fn clear(self: *View, allocator: std.mem.Allocator) void {
        for (&self.masks) |*slot| {
            if (slot.*) |mask| mask.deinit(allocator);
            slot.* = null;
        }
        for (self.parts.items) |part| part.mask.deinit(allocator);
        self.parts.clearRetainingCapacity();
        self.scale = 0;
        self.prompt_height = 0;
    }
    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.parts.deinit(allocator);
        self.renderer.deinit();
    }
    pub fn prepare(self: *View, allocator: std.mem.Allocator, prompt: [:0]const u8, scale: u32) !void {
        if (self.scale == scale) return;
        if (!std.unicode.utf8ValidateSlice(prompt)) return error.InvalidText;
        self.clear(allocator);
        errdefer self.clear(allocator);
        for ([_][:0]const u8{ "SSH Authentication", if (self.mode == .confirm) "Deny" else "Cancel", switch (self.mode) {
            .password => "Unlock",
            .confirm => "Allow",
            .information => "Close",
        } }, 0..) |value, i| {
            self.masks[i] = try self.renderer.renderLayout(allocator, value, .{ .font = "Adwaita Sans Bold", .size = (if (i == 0) @as(f64, 20) else @as(f64, 14.666)) * @as(f64, @floatFromInt(scale)), .dpi = 96 * @as(f64, @floatFromInt(scale)), .origin = .top });
        }
        // Cache public text in bounded paragraphs. Long prompts are scrollable
        // and retain every character, including host-key fingerprints.
        var paragraphs = std.mem.splitScalar(u8, prompt, '\n');
        while (paragraphs.next()) |paragraph| {
            var remaining = paragraph;
            while (true) {
                var size = @min(remaining.len, 512);
                while (size < remaining.len and remaining[size] & 0xc0 == 0x80) size -= 1;
                const value = try allocator.dupeSentinel(u8, remaining[0..size], 0);
                defer allocator.free(value);
                const mask = try self.renderer.renderLayout(allocator, value, .{ .size = 14.666 * @as(f64, @floatFromInt(scale)), .dpi = 96 * @as(f64, @floatFromInt(scale)), .width = (self.width - 48) * scale, .line_height = 20 * scale, .lines = 64, .origin = .top });
                self.parts.append(allocator, .{ .mask = mask, .y = self.prompt_height }) catch |err| {
                    mask.deinit(allocator);
                    return err;
                };
                self.prompt_height += @max(20, std.math.divCeil(u32, mask.logical_height, scale) catch unreachable);
                if (self.prompt_height > 8000) return error.PromptTooLarge;
                remaining = remaining[size..];
                if (remaining.len == 0) break;
            }
        }
        self.height = @intFromFloat(self.buttonRect(.accept).y + 62);
        self.scale = scale;
    }
    pub fn entryRect(self: *const View) Rect {
        return .{ .x = 24, .y = 88 + @as(f64, @floatFromInt(self.prompt_height)), .width = @floatFromInt(self.width - 48), .height = 42 };
    }
    pub fn buttonRect(self: *const View, target: Target) Rect {
        return .{ .x = if (target == .cancel) 24 else @as(f64, @floatFromInt(self.width)) - 148, .y = self.entryRect().y + (if (self.mode == .password) @as(f64, 62) else @as(f64, 0)), .width = 124, .height = 38 };
    }
    pub fn hit(self: *const View, x: f64, y: f64) Target {
        if (self.mode == .password and self.entryRect().contains(x, y)) return .entry;
        if (self.mode != .information and self.buttonRect(.cancel).contains(x, y)) return .cancel;
        if (self.buttonRect(.accept).contains(x, y)) return .accept;
        return .none;
    }
    pub fn stepFocus(self: *View, backward: bool) void {
        const targets: []const Target = switch (self.mode) {
            .password => &.{ .entry, .cancel, .accept },
            .confirm => &.{ .cancel, .accept },
            .information => &.{.accept},
        };
        var index: usize = 0;
        for (targets, 0..) |target, i| if (self.focus == target) {
            index = i;
            break;
        };
        self.focus = targets[(index + (if (backward) targets.len - 1 else 1)) % targets.len];
        self.keyboard_focus = true;
    }
    pub fn paint(self: *const View, target: raster.Buffer) void {
        @memset(target.pixels, 0xff36363a);
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(self.scale) };
        paintMask(canvas, self.masks[0].?, 24, 24);
        for (self.parts.items) |part| paintMask(canvas, part.mask, 24, 68 + @as(f64, @floatFromInt(part.y)));
        for ([_]Target{ .cancel, .accept }, 0..) |button, i| {
            if (button == .cancel and self.mode == .information) continue;
            const rect = self.buttonRect(button);
            const pressed = self.pressed == button and self.hover == button;
            canvas.draw(&.{rect.shape(10)}, color(if (button == .accept) (if (pressed) @as(u32, 0x2265b5) else if (self.hover == button) @as(u32, 0x4390e8) else @as(u32, 0x3584e4)) else (if (pressed) @as(u32, 0x5f5f63) else if (self.hover == button) @as(u32, 0x525256) else @as(u32, 0x48484b))));
            const mask = self.masks[1 + i].?;
            paintMask(canvas, mask, rect.x + (rect.width - @as(f64, @floatFromInt(mask.logical_width)) / canvas.scale) / 2, rect.y + (rect.height - @as(f64, @floatFromInt(mask.logical_height)) / canvas.scale) / 2);
            if (self.focus == button and self.keyboard_focus) canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = rect.x + 2, .y = rect.y + 2, .width = rect.width - 4, .height = rect.height - 4 }, .radius = 8, .width = 2 } }}, color(0x99c1f1));
        }
    }
};
fn color(value: u32) raster.Color {
    return .{ .red = @as(f64, @floatFromInt((value >> 16) & 255)) / 255, .green = @as(f64, @floatFromInt((value >> 8) & 255)) / 255, .blue = @as(f64, @floatFromInt(value & 255)) / 255 };
}
fn paintMask(canvas: raster.Canvas, mask: text.Mask, x: f64, y: f64) void {
    raster.mask(canvas.target, .{ .x = @as(i32, @intFromFloat(x * canvas.scale)) + mask.left, .y = @as(i32, @intFromFloat(y * canvas.scale)) + mask.top, .width = mask.width, .height = mask.height }, mask.pixels, color(0xffffff));
}

test "askpass geometry scales, wraps public text and defaults confirmation to denial" {
    const allocator = std.testing.allocator;
    for ([_]Mode{ .password, .confirm, .information }) |mode| {
        var view = View.init(mode);
        defer view.deinit(allocator);
        for ([_]u32{ 1, 2 }) |scale| {
            try view.prepare(allocator, "Enter passphrase for <test-key> at 100%: 東京\nA second public line.", scale);
            try std.testing.expect(view.prompt_height >= 40);
            const rect = view.buttonRect(.accept);
            try std.testing.expectEqual(Target.accept, view.hit(rect.x + 10, rect.y + 10));
            if (mode == .confirm) try std.testing.expectEqual(Target.cancel, view.focus);
            const count = view.width * view.height * scale * scale;
            const pixels = try allocator.alloc(u32, count + 2);
            defer allocator.free(pixels);
            @memset(pixels, 0x12345678);
            view.paint(.{ .pixels = pixels[1 .. count + 1], .width = view.width * scale, .height = view.height * scale });
            try std.testing.expectEqual(@as(u32, 0x12345678), pixels[0]);
            try std.testing.expectEqual(@as(u32, 0x12345678), pixels[count + 1]);
        }
    }
    var long_view = View.init(.confirm);
    defer long_view.deinit(allocator);
    const long_prompt = try allocator.dupeSentinel(u8, &@as([6000]u8, @splat('x')), 0);
    defer allocator.free(long_prompt);
    try long_view.prepare(allocator, long_prompt, 1);
    try std.testing.expect(long_view.parts.items.len > 10 and long_view.prompt_height > 1000);
    const excessive = try allocator.dupeSentinel(u8, &@as([500]u8, @splat('\n')), 0);
    defer allocator.free(excessive);
    // A preparation failure must release every partially prepared mask once.
    try std.testing.expectError(error.PromptTooLarge, long_view.prepare(allocator, excessive, 2));
}
