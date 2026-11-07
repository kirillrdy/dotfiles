//! Public authentication labels and native geometry. Passwords are drawn by the entry.
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
pub const Target = enum { none, entry, confirmation, cancel, accept, choice0, choice1, choice2 };
pub const Rect = raster.Rect;
pub const Choice = struct { label: [:0]const u8, enabled: bool = true, selected: bool = false };
pub const choice_targets = [_]Target{ .choice0, .choice1, .choice2 };
const Part = struct { mask: text.Mask, y: u32 };
pub const View = struct {
    mode: Mode,
    title: [:0]const u8 = "SSH Authentication",
    accept_label: ?[:0]const u8 = null,
    enabled: bool = true,
    confirmation: bool = false,
    cancel_label: ?[:0]const u8 = null,
    choices: []const Choice = &.{},
    status: ?[:0]const u8 = null,
    status_error: bool = false,
    status_height: u32 = 0,
    width: u32 = 460,
    height: u32 = 0,
    prompt_height: u32 = 0,
    scale: u32 = 0,
    focus: Target,
    keyboard_focus: bool = true,
    hover: Target = .none,
    pressed: Target = .none,
    renderer: text.Renderer = .{},
    masks: [9]?text.Mask = @splat(null),
    parts: std.ArrayList(Part) = .empty,

    pub fn init(mode: Mode) View {
        return .{ .mode = mode, .focus = switch (mode) {
            .password => .entry,
            .confirm => .cancel,
            .information => .accept,
        } };
    }
    pub fn invalidate(self: *View, allocator: std.mem.Allocator) void {
        for (&self.masks) |*slot| {
            if (slot.*) |mask| mask.deinit(allocator);
            slot.* = null;
        }
        for (self.parts.items) |part| part.mask.deinit(allocator);
        self.parts.clearRetainingCapacity();
        self.scale = 0;
        self.prompt_height = 0;
        self.status_height = 0;
    }
    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.invalidate(allocator);
        self.parts.deinit(allocator);
        self.renderer.deinit();
    }
    pub fn prepare(self: *View, allocator: std.mem.Allocator, prompt: [:0]const u8, scale: u32) !void {
        if (self.choices.len > 3 or (self.choices.len != 0 and self.mode != .information)) return error.InvalidChoices;
        if (self.scale == scale) return;
        if (!std.unicode.utf8ValidateSlice(prompt)) return error.InvalidText;
        self.invalidate(allocator);
        errdefer self.invalidate(allocator);
        for ([_][:0]const u8{ self.title, self.cancel_label orelse (if (self.mode == .confirm) "Deny" else "Cancel"), self.accept_label orelse switch (self.mode) {
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
        if (self.confirmation) {
            for ([_][:0]const u8{ "Password", "Confirm password" }, 4..) |value, i| {
                self.masks[i] = try self.renderer.renderLayout(allocator, value, .{ .size = 14.666 * @as(f64, @floatFromInt(scale)), .dpi = 96 * @as(f64, @floatFromInt(scale)), .origin = .top });
            }
        }
        for (self.choices, 6..) |choice, i| {
            self.masks[i] = try self.renderer.renderLayout(allocator, choice.label, .{ .size = 14.666 * @as(f64, @floatFromInt(scale)), .dpi = 96 * @as(f64, @floatFromInt(scale)), .origin = .top });
        }
        if (self.status) |value| {
            self.masks[3] = try self.renderer.renderLayout(allocator, value, .{ .size = 14.666 * @as(f64, @floatFromInt(scale)), .dpi = 96 * @as(f64, @floatFromInt(scale)), .width = (self.width - 48) * scale, .line_height = 20 * scale, .lines = 64, .origin = .top });
            self.status_height = 12 + (std.math.divCeil(u32, self.masks[3].?.logical_height, scale) catch unreachable);
        }
        self.height = @intFromFloat(self.buttonRect(.accept).y + 62);
        self.scale = scale;
    }
    pub fn entryRect(self: *const View) Rect {
        return .{ .x = 24, .y = (if (self.confirmation) @as(f64, 112) else 88) + @as(f64, @floatFromInt(self.prompt_height)), .width = @floatFromInt(self.width - 48), .height = 42 };
    }
    pub fn confirmationRect(self: *const View) Rect {
        var rect = self.entryRect();
        rect.y += 86;
        return rect;
    }
    fn lastEntryRect(self: *const View) Rect {
        return if (self.confirmation) self.confirmationRect() else self.entryRect();
    }
    pub fn choiceRect(self: *const View, index: usize) Rect {
        return .{ .x = 24, .y = self.entryRect().y + @as(f64, @floatFromInt(index * 50)), .width = @floatFromInt(self.width - 48), .height = 42 };
    }
    pub fn targetRect(self: *const View, target: Target) Rect {
        for (choice_targets, 0..) |choice, i| if (target == choice) return self.choiceRect(i);
        return if (target == .entry) self.entryRect() else if (target == .confirmation) self.confirmationRect() else self.buttonRect(target);
    }
    pub fn choiceEnabled(self: *const View, target: Target) bool {
        for (choice_targets, 0..) |choice, i| if (target == choice) return i < self.choices.len and self.enabled and self.choices[i].enabled;
        return false;
    }
    pub fn buttonRect(self: *const View, target: Target) Rect {
        return .{ .x = if (target == .cancel) 24 else @as(f64, @floatFromInt(self.width)) - 148, .y = self.lastEntryRect().y + @as(f64, @floatFromInt(self.choices.len * 50)) + @as(f64, @floatFromInt(self.status_height)) + (if (self.mode == .password) @as(f64, 62) else @as(f64, 0)), .width = 124, .height = 38 };
    }
    pub fn hit(self: *const View, x: f64, y: f64) Target {
        for (self.choices, 0..) |_, i| if (self.choiceEnabled(choice_targets[i]) and self.choiceRect(i).contains(x, y)) return choice_targets[i];
        if (self.confirmation and self.confirmationRect().contains(x, y)) return .confirmation;
        if (self.mode == .password and self.entryRect().contains(x, y)) return .entry;
        if (self.mode != .information and self.buttonRect(.cancel).contains(x, y)) return .cancel;
        if (self.buttonRect(.accept).contains(x, y)) return .accept;
        return .none;
    }
    pub fn stepFocus(self: *View, backward: bool) void {
        var choice_focus: [4]Target = undefined;
        var choice_count: usize = 0;
        for (self.choices, 0..) |_, i| if (self.choiceEnabled(choice_targets[i])) {
            choice_focus[choice_count] = choice_targets[i];
            choice_count += 1;
        };
        choice_focus[choice_count] = .accept;
        const targets: []const Target = if (self.choices.len != 0) choice_focus[0 .. choice_count + 1] else switch (self.mode) {
            .password => if (self.confirmation) &.{ .entry, .confirmation, .cancel, .accept } else &.{ .entry, .cancel, .accept },
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
        if (self.confirmation) {
            paintMask(canvas, self.masks[4].?, 24, self.entryRect().y - 24);
            paintMask(canvas, self.masks[5].?, 24, self.confirmationRect().y - 24);
        }
        if (self.masks[3]) |mask| {
            raster.mask(target, .{ .x = @intFromFloat(24 * canvas.scale), .y = @as(i32, @intFromFloat((self.lastEntryRect().y + 54) * canvas.scale)) + mask.top, .width = mask.width, .height = mask.height }, mask.pixels, color(if (self.status_error) 0xff7b83 else 0xffffff));
        }
        for (self.choices, 0..) |choice, i| {
            const rect = self.choiceRect(i);
            const button = choice_targets[i];
            const active = self.choiceEnabled(button);
            canvas.draw(&.{rect.shape(10)}, color(if (!active) @as(u32, 0x404044) else if (choice.selected) @as(u32, 0x2265b5) else if (self.hover == button) @as(u32, 0x525256) else @as(u32, 0x48484b)));
            paintMaskTint(canvas, self.masks[6 + i].?, rect.x + 16, rect.y + 12, if (active) 0xffffff else 0x929296);
            if (choice.selected) canvas.draw(&.{.{ .circle = .{ .center = .{ .x = rect.x + rect.width - 20, .y = rect.y + 21 }, .radius = 4 } }}, color(0xffffff));
            if (self.focus == button and self.keyboard_focus) canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = rect.x + 2, .y = rect.y + 2, .width = rect.width - 4, .height = rect.height - 4 }, .radius = 8, .width = 2 } }}, color(0x99c1f1));
        }
        for ([_]Target{ .cancel, .accept }, 0..) |button, i| {
            if (button == .cancel and self.mode == .information) continue;
            const rect = self.buttonRect(button);
            const pressed = self.pressed == button and self.hover == button;
            canvas.draw(&.{rect.shape(10)}, color(if (button == .accept and !self.enabled) @as(u32, 0x48484b) else if (button == .accept) (if (pressed) @as(u32, 0x2265b5) else if (self.hover == button) @as(u32, 0x4390e8) else @as(u32, 0x3584e4)) else (if (pressed) @as(u32, 0x5f5f63) else if (self.hover == button) @as(u32, 0x525256) else @as(u32, 0x48484b))));
            const mask = self.masks[1 + i].?;
            paintMask(canvas, mask, rect.x + (rect.width - @as(f64, @floatFromInt(mask.logical_width)) / canvas.scale) / 2, rect.y + (rect.height - @as(f64, @floatFromInt(mask.logical_height)) / canvas.scale) / 2);
            if (self.focus == button and self.keyboard_focus) canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = rect.x + 2, .y = rect.y + 2, .width = rect.width - 4, .height = rect.height - 4 }, .radius = 8, .width = 2 } }}, color(0x99c1f1));
        }
    }
};
fn color(value: u32) raster.Color {
    return raster.Color.rgb(value, 1);
}
fn paintMask(canvas: raster.Canvas, mask: text.Mask, x: f64, y: f64) void {
    mask.paint(canvas, x, y, color(0xffffff));
}
fn paintMaskTint(canvas: raster.Canvas, mask: text.Mask, x: f64, y: f64, tint: u32) void {
    mask.paint(canvas, x, y, color(tint));
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

test "password confirmation fields, status and actions stay distinct at both scales" {
    const allocator = std.testing.allocator;
    var view = View.init(.password);
    defer view.deinit(allocator);
    view.confirmation = true;
    view.title = "Create Password Vault";
    view.accept_label = "Create";
    view.status = "Passwords do not match. Please try again.";
    view.status_error = true;
    for ([_]u32{ 1, 2 }) |scale| {
        try view.prepare(allocator, "Choose a password for your new password vault. 東京", scale);
        const first = view.entryRect();
        const second = view.confirmationRect();
        const button = view.buttonRect(.accept);
        try std.testing.expect(first.y + first.height + 24 <= second.y);
        try std.testing.expect(second.y + second.height + @as(f64, @floatFromInt(view.status_height)) <= button.y);
        try std.testing.expectEqual(Target.confirmation, view.hit(second.x + 10, second.y + 10));
        view.focus = .entry;
        view.stepFocus(false);
        try std.testing.expectEqual(Target.confirmation, view.focus);
        view.stepFocus(true);
        try std.testing.expectEqual(Target.entry, view.focus);
        const count = view.width * view.height * scale * scale;
        const pixels = try allocator.alloc(u32, count + 2);
        defer allocator.free(pixels);
        @memset(pixels, 0x12345678);
        view.paint(.{ .pixels = pixels[1 .. count + 1], .width = view.width * scale, .height = view.height * scale });
        try std.testing.expectEqual(@as(u32, 0x12345678), pixels[0]);
        try std.testing.expectEqual(@as(u32, 0x12345678), pixels[count + 1]);
    }
}

test "native dialog choices skip unavailable modes and keep actions below rows" {
    const allocator = std.testing.allocator;
    var view = View.init(.information);
    defer view.deinit(allocator);
    const choices = [_]Choice{
        .{ .label = "Performance", .enabled = false },
        .{ .label = "Balanced", .selected = true },
        .{ .label = "Power Saver" },
    };
    view.choices = &choices;
    for ([_]u32{ 1, 2 }) |scale| {
        try view.prepare(allocator, "Choose a power mode.", scale);
        try std.testing.expect(view.choiceRect(2).y + 42 <= view.buttonRect(.accept).y);
        const rect = view.choiceRect(1);
        try std.testing.expectEqual(Target.choice1, view.hit(rect.x + 1, rect.y + 1));
        view.focus = .accept;
        view.stepFocus(false);
        try std.testing.expectEqual(Target.choice1, view.focus);
        view.stepFocus(false);
        try std.testing.expectEqual(Target.choice2, view.focus);
        view.stepFocus(false);
        try std.testing.expectEqual(Target.accept, view.focus);
        view.stepFocus(true);
        try std.testing.expectEqual(Target.choice2, view.focus);
        const count = view.width * view.height * scale * scale;
        const pixels = try allocator.alloc(u32, count + 2);
        defer allocator.free(pixels);
        @memset(pixels, 0x12345678);
        view.paint(.{ .pixels = pixels[1 .. count + 1], .width = view.width * scale, .height = view.height * scale });
        try std.testing.expectEqual(@as(u32, 0x12345678), pixels[0]);
        try std.testing.expectEqual(@as(u32, 0x12345678), pixels[count + 1]);
    }
}
