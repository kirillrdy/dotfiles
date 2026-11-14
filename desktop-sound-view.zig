//! GNOME Sound cards, device selectors and application volume controls.
const std = @import("std");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const audio = @import("desktop-audio.zig");
const p = @import("desktop-preferences-view.zig");
pub const Rect = raster.Rect;
pub const Control = enum { volume, mute, default, device, levels, back, close, test_sound };
pub const Page = enum { sound, levels };
pub const Target = struct {
    row: usize = 0,
    control: Control = .volume,
    pub fn eql(self: Target, other: Target) bool {
        return self.row == other.row and self.control == other.control;
    }
};
pub const Row = struct {
    target: audio.Target,
    title: [:0]const u8,
    class: ?audio.Class = null,
    device: bool = false,
    state: ?audio.State = null,
    is_default: bool = false,
    pending: ?f64 = null,
    pending_target: ?audio.Target = null,
    title_mask: ?text.Mask = null,
    summary_mask: ?text.Mask = null,
    pub fn invalidate(self: *Row, allocator: std.mem.Allocator) void {
        for ([_]?text.Mask{ self.title_mask, self.summary_mask }) |mask| if (mask) |m| m.deinit(allocator);
        self.title_mask = null;
        self.summary_mask = null;
    }
};
const Label = enum { settings, sound, output, input, output_device, input_device, output_volume, input_volume, sounds, levels, outputs, inputs, no_streams, no_output, no_input, test_sound, sound_nav, levels_title };
const captions = [_][:0]const u8{ "Settings", "Sound", "Output", "Input", "Output Device", "Input Device", "Output Volume", "Input Volume", "Sounds", "Volume Levels", "Outputs", "Inputs", "No Sound Playing", "No Output Devices", "No Input Devices", "Test", "Sound", "Volume Levels" };
pub const View = struct {
    rows: std.ArrayList(Row) = .empty,
    width: u32 = 980,
    viewport_height: u32 = 700,
    scale: u32 = 0,
    page: Page = .sound,
    expanded: ?usize = null,
    option_cursor: usize = 0,
    offset: f64 = 0,
    focus: ?Target = null,
    hover: ?Target = null,
    pressed: ?Target = null,
    keyboard_focus: bool = false,
    enabled: bool = true,
    test_enabled: bool = false,
    renderer: text.Renderer = .{},
    labels: [captions.len]?text.Mask = @splat(null),
    icons: p.Icons = .{},
    message: [:0]const u8 = "",
    message_mask: ?text.Mask = null,
    pub fn invalidate(self: *View, allocator: std.mem.Allocator) void {
        for (self.rows.items) |*row| row.invalidate(allocator);
        for (&self.labels) |*mask| {
            if (mask.*) |m| m.deinit(allocator);
            mask.* = null;
        }
        if (self.message_mask) |mask| mask.deinit(allocator);
        self.message_mask = null;
        self.scale = 0;
    }
    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.invalidate(allocator);
        for (self.rows.items) |row| allocator.free(row.title);
        self.rows.deinit(allocator);
        self.icons.deinit();
        self.renderer.deinit();
    }
    pub fn sidebar(self: *const View) f64 {
        return @min(280, @as(f64, @floatFromInt(self.width)) * 0.3);
    }
    pub fn contentWidth(self: *const View) f64 {
        return @min(576, @as(f64, @floatFromInt(self.width)) - self.sidebar() - 48);
    }
    pub fn contentX(self: *const View) f64 {
        return self.sidebar() + (@as(f64, @floatFromInt(self.width)) - self.sidebar() - self.contentWidth()) / 2;
    }
    fn stream(self: *const View, index: usize) bool {
        const row = self.rows.items[index];
        return row.state != null and (row.class == .playback or row.class == .recording);
    }
    pub fn rowY(self: *const View, index: usize) f64 {
        if (index < 2) return (if (index == 0) @as(f64, 165) else 347) - self.offset;
        var y: f64 = 70;
        for ([_]audio.Class{ .playback, .recording }) |class| {
            var first = true;
            for (self.rows.items, 0..) |row, i| {
                if (row.class != class or !self.stream(i)) continue;
                if (first) y += 40;
                first = false;
                if (i == index) return y - self.offset;
                y += 63;
            }
            if (!first) y += 24;
        }
        return -1000;
    }
    pub fn height(self: *const View) u32 {
        if (self.page == .sound) return 553;
        var extent: f64 = 180;
        for (self.rows.items, 0..) |_, i| if (self.stream(i)) {
            extent = @max(extent, self.rowY(i) + self.offset + 87);
        };
        return @intFromFloat(extent);
    }
    pub fn maxOffset(self: *const View) f64 {
        return @max(0, @as(f64, @floatFromInt(self.height())) - @as(f64, @floatFromInt(self.viewport_height)));
    }
    fn groupRect(self: *const View, input: bool) Rect {
        return .{ .x = self.contentX(), .y = (if (input) @as(f64, 292) else 110) - self.offset, .width = self.contentWidth(), .height = if (self.rows.items.len > @as(usize, @intFromBool(input)) and self.rows.items[@intFromBool(input)].state != null) 118 else 55 };
    }
    fn deviceClass(index: usize) audio.Class {
        return if (index == 0) .output else .input;
    }
    fn deviceCount(self: *const View, index: usize) usize {
        var count: usize = 0;
        for (self.rows.items) |row| if (row.device and row.class == deviceClass(index) and row.state != null) {
            count += 1;
        };
        return count;
    }
    pub fn optionAt(self: *const View, position: usize) ?usize {
        const master = self.expanded orelse return null;
        var ordinal: usize = 0;
        for (self.rows.items, 0..) |row, i| {
            if (!row.device or row.class != deviceClass(master) or row.state == null) continue;
            if (ordinal == position) return i;
            ordinal += 1;
        }
        return null;
    }
    pub fn menuRect(self: *const View) Rect {
        const master = self.expanded orelse return .{};
        const field = self.rect(.{ .row = master, .control = .device });
        const h = @as(f64, @floatFromInt(@min(self.deviceCount(master), self.menuCapacity()) * 44)) + 12;
        const viewport: f64 = @floatFromInt(self.viewport_height);
        return .{ .x = field.x + 8, .y = std.math.clamp(field.y + field.height + 4, 50, @max(50, viewport - h - 12)), .width = field.width - 16, .height = h };
    }
    fn menuCapacity(self: *const View) usize {
        return @intFromFloat(@max(1, @floor((@as(f64, @floatFromInt(self.viewport_height)) - 74) / 44)));
    }
    fn optionStart(self: *const View) usize {
        return if (self.option_cursor >= self.menuCapacity()) self.option_cursor - self.menuCapacity() + 1 else 0;
    }
    pub fn rect(self: *const View, target: Target) Rect {
        const x = self.contentX();
        const w = self.contentWidth();
        const y = if (target.row < self.rows.items.len) self.rowY(target.row) else @as(f64, -1000);
        return switch (target.control) {
            .volume => .{ .x = x + (if (target.row < 2) @as(f64, 174) else 218), .y = y + 14, .width = w - (if (target.row < 2) @as(f64, 190) else 234), .height = 36 },
            .mute => .{ .x = x + (if (target.row < 2) @as(f64, 128) else 172), .y = y + 14, .width = 36, .height = 36 },
            .default => blk: {
                const menu = self.menuRect();
                var ordinal: usize = 0;
                for (self.rows.items, 0..) |row, i| {
                    if (!row.device or row.class != deviceClass(self.expanded orelse 0) or row.state == null) continue;
                    if (i == target.row) break;
                    ordinal += 1;
                }
                break :blk .{ .x = menu.x + 6, .y = menu.y + 6 + (@as(f64, @floatFromInt(ordinal)) - @as(f64, @floatFromInt(self.optionStart()))) * 44, .width = menu.width - 12, .height = 44 };
            },
            .device => blk: {
                var r = self.groupRect(target.row == 1);
                r.height = 55;
                break :blk r;
            },
            .levels => .{ .x = x, .y = 474 - self.offset, .width = w, .height = 55 },
            .back => .{ .x = self.sidebar() + 6, .y = 6, .width = 34, .height = 34 },
            .close => .{ .x = @as(f64, @floatFromInt(self.width)) - 35, .y = 11, .width = 24, .height = 24 },
            .test_sound => .{ .x = x + w - 80, .y = 70 - self.offset, .width = 80, .height = 34 },
        };
    }
    pub fn active(self: *const View, target: Target) bool {
        switch (target.control) {
            .close => return true,
            .back => return self.page == .levels,
            .levels => return self.page == .sound,
            .test_sound => return self.enabled and self.page == .sound and self.test_enabled and self.rows.items.len > 0 and self.rows.items[0].state != null,
            else => {},
        }
        if (!self.enabled or target.row >= self.rows.items.len) return false;
        const row = self.rows.items[target.row];
        return switch (target.control) {
            .volume, .mute => row.state != null and (if (self.page == .sound) target.row < 2 else self.stream(target.row)),
            .device => self.page == .sound and target.row < 2 and self.deviceCount(target.row) > 1,
            .default => self.page == .sound and self.expanded != null and row.device and row.class == deviceClass(self.expanded.?) and row.state != null,
            else => false,
        };
    }
    pub fn hit(self: *const View, x: f64, y: f64) ?Target {
        if (self.rect(.{ .control = .close }).contains(x, y)) return .{ .control = .close };
        if (self.expanded != null) {
            var n = self.optionStart();
            while (n < self.optionStart() + self.menuCapacity()) : (n += 1) {
                const i = self.optionAt(n) orelse break;
                const t: Target = .{ .row = i, .control = .default };
                if (self.rect(t).contains(x, y)) return t;
            }
            return null;
        }
        for ([_]Control{ .back, .levels, .test_sound }) |control| {
            const t: Target = .{ .control = control };
            if (control != .back and y < 46) continue;
            if (self.active(t) and self.rect(t).contains(x, y)) return t;
        }
        if (y < 46 or y > @as(f64, @floatFromInt(self.viewport_height)) or x < self.sidebar()) return null;
        for (self.rows.items, 0..) |_, i| for ([_]Control{ .volume, .mute, .device }) |control| {
            const t: Target = .{ .row = i, .control = control };
            if (self.active(t) and self.rect(t).contains(x, y)) return t;
        };
        return null;
    }
    pub fn percent(self: *const View, target: Target, x: f64) f64 {
        const r = self.rect(target);
        return @round(std.math.clamp((x - r.x - 8) / (r.width - 16), 0, 1) * 100);
    }
    pub fn moveFocus(self: *View, backwards: bool) void {
        const count = self.rows.items.len * 4 + 4;
        const start = if (self.focus) |f| switch (f.control) {
            .volume, .mute, .default, .device => f.row * 4 + @as(usize, @backingInt(f.control)),
            .levels => count - 4,
            .back => count - 3,
            .test_sound => count - 2,
            .close => count - 1,
        } else if (backwards) @as(usize, 0) else count - 1;
        for (1..count + 1) |step| {
            const index = if (backwards) (start + count - step) % count else (start + step) % count;
            const t: Target = if (index < count - 4) .{ .row = index / 4, .control = @fromBackingInt(@intCast(index % 4)) } else .{ .control = ([_]Control{ .levels, .back, .test_sound, .close })[index - (count - 4)] };
            if (self.active(t)) {
                self.focus = t;
                self.keyboard_focus = true;
                return;
            }
        }
        self.focus = null;
    }
    pub fn prepare(self: *View, allocator: std.mem.Allocator, scale: u32) !void {
        if (self.scale != scale) {
            self.invalidate(allocator);
            self.scale = scale;
        }
        const factor: f64 = @floatFromInt(scale);
        for (captions, &self.labels, 0..) |label_text, *mask, i| {
            const bold = i <= 3 or i == 8 or i == 10 or i == 11 or i == 12 or i == 15 or i == 17;
            if (mask.* == null) mask.* = try self.renderer.renderLayout(allocator, label_text, .{ .font = if (bold) "Adwaita Sans Bold" else "Adwaita Sans", .size = (if (i == 12) @as(f64, 24) else 14.666) * factor, .dpi = 96 * factor, .origin = .top });
        }
        if (self.message.len != 0 and self.message_mask == null) self.message_mask = try self.renderer.renderLayout(allocator, self.message, .{ .font = "Adwaita Sans", .size = 13 * factor, .dpi = 96 * factor, .width = @intFromFloat((self.contentWidth() - 32) * factor), .lines = 3, .ellipsize = true, .origin = .top });
        for (self.rows.items) |*row| {
            if (row.title_mask == null) row.title_mask = try self.renderer.renderLayout(allocator, row.title, .{ .font = "Adwaita Sans", .size = 14.666 * factor, .dpi = 96 * factor, .width = @intFromFloat((self.contentWidth() - 72) * factor), .ellipsize = true, .lines = 1, .origin = .top });
            if (row.summary_mask == null) row.summary_mask = try self.renderer.renderLayout(allocator, row.title, .{ .font = "Adwaita Sans", .size = 14.666 * factor, .dpi = 96 * factor, .width = @intFromFloat((if (row.device) self.contentWidth() * 0.58 - 36 else @as(f64, 126)) * factor), .ellipsize = true, .lines = 1, .origin = .top });
        }
    }
    fn caption(self: *const View, canvas: raster.Canvas, label: Label, bounds: Rect, centered: bool, tint: u32) void {
        self.drawMask(canvas, self.labels[@backingInt(label)].?, bounds, centered, tint);
    }
    fn drawMask(_: *const View, canvas: raster.Canvas, mask: text.Mask, bounds: Rect, centered: bool, tint: u32) void {
        const w: f64 = @as(f64, @floatFromInt(mask.logical_width)) / canvas.scale;
        const h: f64 = @as(f64, @floatFromInt(mask.logical_height)) / canvas.scale;
        mask.paint(canvas, bounds.x + (if (centered) (bounds.width - w) / 2 else 0), bounds.y + (bounds.height - h) / 2, color(tint));
    }
    fn icon(self: *View, canvas: raster.Canvas, name: [:0]const u8, bounds: Rect, size: u32) void {
        self.icons.paint(canvas, name, bounds.x + (bounds.width - @as(f64, @floatFromInt(size))) / 2, bounds.y + (bounds.height - @as(f64, @floatFromInt(size))) / 2, size) catch {};
    }
    fn controlFocus(self: *const View, canvas: raster.Canvas, t: Target) void {
        if (self.keyboard_focus) if (self.focus) |f| if (f.eql(t) and self.active(t)) p.focus(canvas, self.rect(t));
    }
    fn slider(self: *View, canvas: raster.Canvas, i: usize) void {
        const row = self.rows.items[i];
        const t: Target = .{ .row = i };
        const r = self.rect(t);
        const value = std.math.clamp(row.pending orelse row.state.?.percent, 0, 100);
        const knob = r.x + 8 + (r.width - 16) * value / 100;
        const muted = row.state.?.muted;
        p.fill(canvas, .{ .x = r.x + 8, .y = r.y + 16, .width = r.width - 16, .height = 4 }, 0x626266, 2);
        p.fill(canvas, .{ .x = r.x + 8, .y = r.y + 16, .width = @max(0.01, knob - r.x - 8), .height = 4 }, if (muted) 0x929296 else 0x3584e4, 2);
        canvas.draw(&.{.{ .circle = .{ .center = .{ .x = knob, .y = r.y + 18 }, .radius = 10 } }}, color(0xd5d5d7));
        const mute: Target = .{ .row = i, .control = .mute };
        const mr = self.rect(mute);
        if (self.hover) |h| if (h.eql(mute)) p.fill(canvas, mr, 0x47474b, 6);
        const input = i == 1 or row.class == .recording;
        self.icon(canvas, if (input) (if (muted) "microphone-sensitivity-muted-symbolic" else "audio-input-microphone-symbolic") else if (muted) "audio-volume-muted-symbolic" else if (value < 34) "audio-volume-low-symbolic" else if (value < 67) "audio-volume-medium-symbolic" else "audio-volume-high-symbolic", mr, 16);
        self.controlFocus(canvas, t);
        self.controlFocus(canvas, mute);
    }
    pub fn paint(self: *View, target: raster.Buffer) void {
        @memset(target.pixels, 0xff222226);
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(self.scale) };
        const x = self.contentX();
        const w = self.contentWidth();
        if (self.page == .sound) {
            for ([_]bool{ false, true }, 0..) |input, i| {
                const r = self.groupRect(input);
                self.caption(canvas, if (input) .input else .output, .{ .x = x, .y = r.y - 40, .width = w, .height = 34 }, false, 0xffffff);
                p.fill(canvas, r, p.card, 12);
                self.caption(canvas, if (input) .input_device else .output_device, .{ .x = x + 14, .y = r.y, .width = 140, .height = 55 }, false, 0xffffff);
                var selected: ?usize = null;
                for (self.rows.items, 0..) |row, n| if (row.device and row.class == deviceClass(i) and row.is_default) {
                    selected = n;
                    break;
                };
                if (selected) |n| {
                    // Device labels have their own bounded mask so long names cannot cover the row title.
                    if (self.rows.items[n].summary_mask) |mask| {
                        const label_width = @as(f64, @floatFromInt(mask.logical_width)) / canvas.scale;
                        const label_x = x + w - (if (self.deviceCount(i) > 1) @as(f64, 36) else 14) - label_width;
                        self.drawMask(canvas, mask, .{ .x = label_x, .y = r.y, .width = label_width, .height = 55 }, false, 0xffffff);
                        self.icon(canvas, if (input) "audio-input-microphone-symbolic" else "audio-speakers-symbolic", .{ .x = label_x - 24, .y = r.y, .width = 20, .height = 55 }, 16);
                    }
                    if (self.active(.{ .row = i, .control = .device })) self.icon(canvas, "pan-down-symbolic", .{ .x = x + w - 36, .y = r.y, .width = 28, .height = 55 }, 16);
                } else self.caption(canvas, if (input) .no_input else .no_output, .{ .x = x + 160, .y = r.y, .width = w - 174, .height = 55 }, false, p.secondary);
                self.controlFocus(canvas, .{ .row = i, .control = .device });
                if (i < self.rows.items.len and self.rows.items[i].state != null) {
                    p.line(canvas, x, r.y + 55, w);
                    self.caption(canvas, if (input) .input_volume else .output_volume, .{ .x = x + 14, .y = r.y + 55, .width = 114, .height = 63 }, false, 0xffffff);
                    self.slider(canvas, i);
                }
            }
            const test_target: Target = .{ .control = .test_sound };
            const tr = self.rect(test_target);
            p.fill(canvas, tr, if (self.hover != null and self.hover.?.eql(test_target)) 0x47474b else 0x3d3d41, 8);
            self.caption(canvas, .test_sound, tr, true, if (self.active(test_target)) 0xffffff else p.secondary);
            self.controlFocus(canvas, test_target);
            self.caption(canvas, .sounds, .{ .x = x, .y = 434 - self.offset, .width = w, .height = 34 }, false, 0xffffff);
            const lr = self.rect(.{ .control = .levels });
            p.fill(canvas, lr, p.card, 12);
            self.caption(canvas, .levels, .{ .x = x + 14, .y = lr.y, .width = w - 56, .height = 55 }, false, 0xffffff);
            self.icon(canvas, "go-next-symbolic", .{ .x = x + w - 36, .y = lr.y, .width = 28, .height = 55 }, 16);
            self.controlFocus(canvas, .{ .control = .levels });
        } else {
            var count: usize = 0;
            for ([_]audio.Class{ .playback, .recording }) |class| {
                var first: ?usize = null;
                var total: usize = 0;
                for (self.rows.items, 0..) |row, i| if (row.class == class and self.stream(i)) {
                    if (first == null) first = i;
                    total += 1;
                };
                if (first) |n| {
                    const y = self.rowY(n);
                    self.caption(canvas, if (class == .playback) .outputs else .inputs, .{ .x = x, .y = y - 40, .width = w, .height = 34 }, false, 0xffffff);
                    p.fill(canvas, .{ .x = x, .y = y, .width = w, .height = @as(f64, @floatFromInt(total * 63)) }, p.card, 12);
                }
                var ordinal: usize = 0;
                for (self.rows.items, 0..) |row, i| if (row.class == class and self.stream(i)) {
                    const y = self.rowY(i);
                    if (ordinal > 0) p.line(canvas, x, y, w);
                    self.icon(canvas, if (class == .playback) "audio-x-generic-symbolic" else "audio-input-microphone-symbolic", .{ .x = x + 12, .y = y, .width = 24, .height = 63 }, 24);
                    if (row.summary_mask) |mask| self.drawMask(canvas, mask, .{ .x = x + 44, .y = y, .width = 126, .height = 63 }, false, 0xffffff);
                    self.slider(canvas, i);
                    ordinal += 1;
                    count += 1;
                };
            }
            if (count == 0) {
                const y = @max(140, @as(f64, @floatFromInt(self.viewport_height)) / 2 - 70);
                self.icon(canvas, "audio-volume-high-symbolic", .{ .x = x, .y = y, .width = w, .height = 64 }, 64);
                self.caption(canvas, .no_streams, .{ .x = x, .y = y + 88, .width = w, .height = 36 }, true, 0xffffff);
            }
        }
        // Fixed chrome covers scrolled content and cannot be hit through.
        p.fill(canvas, .{ .x = 0, .y = 0, .width = self.sidebar(), .height = @floatFromInt(self.viewport_height) }, 0x2e2e32, 0);
        p.fill(canvas, .{ .x = self.sidebar(), .y = 0, .width = @as(f64, @floatFromInt(self.width)) - self.sidebar(), .height = 46 }, p.background, 0);
        self.caption(canvas, .settings, .{ .x = 0, .y = 0, .width = self.sidebar(), .height = 46 }, true, 0xffffff);
        self.caption(canvas, if (self.page == .sound) .sound else .levels_title, .{ .x = self.sidebar(), .y = 0, .width = @as(f64, @floatFromInt(self.width)) - self.sidebar(), .height = 46 }, true, 0xffffff);
        p.fill(canvas, .{ .x = 6, .y = 52, .width = self.sidebar() - 12, .height = 43 }, 0x414145, 8);
        self.icon(canvas, "audio-volume-high-symbolic", .{ .x = 16, .y = 52, .width = 24, .height = 43 }, 16);
        self.caption(canvas, .sound_nav, .{ .x = 48, .y = 52, .width = self.sidebar() - 60, .height = 43 }, false, 0xffffff);
        const close_target: Target = .{ .control = .close };
        p.fill(canvas, self.rect(close_target), 0x38383c, 12);
        self.icon(canvas, "window-close-symbolic", self.rect(close_target), 12);
        self.controlFocus(canvas, close_target);
        if (self.page == .levels) {
            self.icon(canvas, "go-previous-symbolic", self.rect(.{ .control = .back }), 16);
            self.controlFocus(canvas, .{ .control = .back });
        }
        if (self.expanded != null) {
            const mr = self.menuRect();
            p.fill(canvas, .{ .x = mr.x - 1, .y = mr.y - 1, .width = mr.width + 2, .height = mr.height + 2 }, 0x5c5c60, 12);
            p.fill(canvas, mr, 0x38383c, 11);
            var n = self.optionStart();
            while (n < self.optionStart() + self.menuCapacity()) : (n += 1) {
                const i = self.optionAt(n) orelse break;
                const t: Target = .{ .row = i, .control = .default };
                const r = self.rect(t);
                if (n == self.option_cursor or (self.hover != null and self.hover.?.eql(t))) p.fill(canvas, r, 0x4b4b50, 6);
                self.drawMask(canvas, self.rows.items[i].title_mask.?, .{ .x = r.x + 12, .y = r.y, .width = r.width - 56, .height = r.height }, false, 0xffffff);
                if (self.rows.items[i].is_default) self.icon(canvas, "object-select-symbolic", .{ .x = r.x + r.width - 36, .y = r.y, .width = 24, .height = 44 }, 16);
            }
        }
        if (self.message_mask) |mask| {
            const h = @as(f64, @floatFromInt(mask.logical_height)) / canvas.scale + 20;
            const r = Rect{ .x = x + 8, .y = @as(f64, @floatFromInt(self.viewport_height)) - h - 16, .width = w - 16, .height = h };
            p.fill(canvas, r, 0x45454b, 10);
            self.drawMask(canvas, mask, r, true, 0xffffff);
        }
    }
};
const color = raster.hex;

test "sound cards clamp sliders and device menu hit testing blocks controls behind it" {
    const allocator = std.testing.allocator;
    var view: View = .{};
    defer view.deinit(allocator);
    try view.rows.append(allocator, .{ .target = .output, .title = try allocator.dupeSentinel(u8, "Output Volume", 0), .state = .{ .percent = 50 } });
    try view.rows.append(allocator, .{ .target = .input, .title = try allocator.dupeSentinel(u8, "Input Volume", 0) });
    for ([_]bool{ true, false }) |selected| try view.rows.append(allocator, .{ .target = .{ .id = if (selected) 10 else 11 }, .title = try allocator.dupeSentinel(u8, "Speakers", 0), .class = .output, .device = true, .state = .{ .percent = 50 }, .is_default = selected });
    try std.testing.expectEqual(@as(f64, 0), view.percent(.{}, -100));
    try std.testing.expectEqual(@as(f64, 100), view.percent(.{}, 10000));
    view.moveFocus(false);
    try std.testing.expect(view.focus.?.eql(.{}));
    view.moveFocus(false);
    try std.testing.expect(view.focus.?.eql(.{ .control = .mute }));
    view.moveFocus(false);
    try std.testing.expect(view.focus.?.eql(.{ .control = .device }));
    view.moveFocus(false);
    try std.testing.expect(view.focus.?.eql(.{ .control = .levels }));
    view.moveFocus(false);
    try std.testing.expect(view.focus.?.eql(.{ .control = .close }));
    view.moveFocus(false);
    try std.testing.expect(view.focus.?.eql(.{}));
    view.expanded = 0;
    const option = view.rect(.{ .row = 3, .control = .default });
    try std.testing.expect(view.hit(option.x + 20, option.y + 20).?.eql(.{ .row = 3, .control = .default }));
    try std.testing.expect(view.hit(10, 150) == null);
    view.expanded = null;
    view.enabled = false;
    const bounds = view.rect(.{});
    try std.testing.expect(view.hit(bounds.x + 20, bounds.y + 5) == null);
}

test "sound view renders long labels and empty stream page at both scales" {
    const allocator = std.testing.allocator;
    var view: View = .{};
    defer view.deinit(allocator);
    view.message = "Audio service unavailable";
    try view.rows.append(allocator, .{ .target = .output, .title = try allocator.dupeSentinel(u8, "A long device title that should not cover adjacent controls", 0), .state = .{ .percent = 135, .muted = true } });
    try view.rows.append(allocator, .{ .target = .input, .title = try allocator.dupeSentinel(u8, "None available", 0) });
    for ([_]u32{ 1, 2 }) |scale| {
        try view.prepare(allocator, scale);
        const pixels = try allocator.alloc(u32, view.width * view.viewport_height * scale * scale);
        defer allocator.free(pixels);
        for ([_]Page{ .sound, .levels }) |page| {
            view.page = page;
            view.paint(.{ .pixels = pixels, .width = view.width * scale, .height = view.viewport_height * scale });
            try std.testing.expect(std.mem.count(u32, pixels, &.{0xff222226}) < pixels.len);
        }
    }
}
