//! Pixel-perfect GDM login screen renderer, layout, and hit testing.
//! No password bytes enter this view; it only receives a character count.
const std = @import("std");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const decode = @import("desktop-decode.zig");
const icons = @import("desktop-icons.zig");
const c = @import("desktop-glib.zig");

pub const Stage = enum { user_list, username, password };
pub const Status = enum { ready, authenticating, failed };
pub const PowerAction = enum { @"suspend", reboot, poweroff };

pub const UserEntry = struct {
    username: []const u8,
    display_name: []const u8,
    avatar_path: ?[*:0]const u8 = null,
};

pub const Target = union(enum) {
    none,
    user: usize,
    not_listed,
    back,
    entry,
    submit,
    power_button,
    power_action: PowerAction,
};

pub const Frame = struct {
    stage: Stage = .user_list,
    status: Status = .ready,
    /// Selected index in user_list (0..users.len-1 = user, users.len = "Not listed?").
    selected: usize = 0,
    /// Active user index in .password stage, or null if entered via "Not listed?".
    active_user: ?usize = null,
    /// Typed username in .username stage (or custom username shown in .password stage).
    username_text: []const u8 = "",
    /// Password character count shown as bullets.
    typed: usize = 0,
    caps_lock: bool = false,
    spin: f64 = 0,
    power_menu_open: bool = false,
    hover: Target = .none,
};

// GNOME Shell / GDM Adwaita dark palette.
pub const background_pixel: u32 = 0xff222226;
const popover_bg: u32 = 0x2e2e32;
const warning: u32 = 0xf8e45c;
const accent: u32 = 0x3584e4;

const top_bar_height: f64 = 32;
const list_width: f64 = 340;
const user_row_height: f64 = 72;
const user_row_gap: f64 = 8;
const user_row_radius: f64 = 12;
const list_avatar_size: f64 = 48;
const not_listed_height: f64 = 32;
const not_listed_gap: f64 = 16;

const prompt_avatar_size: f64 = 96;
const entry_width: f64 = 280;
const entry_height: f64 = 36;
const button_size: f64 = 36;
const row_spacing: f64 = 12;
const dot_radius: f64 = 3.5;
const dot_spacing: usize = 11;
const max_dots: usize = (280 - 24) / dot_spacing;

const power_pill_width: f64 = 40;
const power_pill_height: f64 = 24;
const power_menu_width: f64 = 188;
const power_item_height: f64 = 36;
const power_menu_pad: f64 = 6;

const StaticLabel = enum {
    clock,
    not_listed,
    username_title,
    username_placeholder,
    password_placeholder,
    failed,
    caps,
    @"suspend",
    restart,
    power_off,
};
const static_label_count = @typeInfo(StaticLabel).@"enum".field_names.len;

pub const Layout = struct {
    width: f64,
    height: f64,
    user_count: usize,
    power_button: raster.Rect,
    power_menu: raster.Rect,
    power_items: [3]raster.Rect,
    list_top: f64,
    list_x: f64,
    not_listed: raster.Rect,
    prompt_top: f64,
    back: raster.Rect,
    entry: raster.Rect,
    submit: raster.Rect,

    pub fn compute(width: f64, height: f64, user_count: usize) Layout {
        const power_button: raster.Rect = .{
            .x = @max(0, width - power_pill_width - 8),
            .y = (top_bar_height - power_pill_height) / 2,
            .width = power_pill_width,
            .height = power_pill_height,
        };
        const menu_h = 3 * power_item_height + 2 * power_menu_pad;
        const power_menu: raster.Rect = .{
            .x = @max(8, width - power_menu_width - 8),
            .y = top_bar_height + 6,
            .width = power_menu_width,
            .height = menu_h,
        };
        var power_items: [3]raster.Rect = undefined;
        for (&power_items, 0..) |*item, i| {
            item.* = .{
                .x = power_menu.x + power_menu_pad,
                .y = power_menu.y + power_menu_pad + @as(f64, @floatFromInt(i)) * power_item_height,
                .width = power_menu.width - 2 * power_menu_pad,
                .height = power_item_height,
            };
        }

        const rows_h = if (user_count == 0) 0 else @as(f64, @floatFromInt(user_count)) * user_row_height + @as(f64, @floatFromInt(user_count - 1)) * user_row_gap;
        const total_list_h = rows_h + (if (user_count > 0) not_listed_gap else 0) + not_listed_height;
        const avail_h = @max(0, height - top_bar_height);
        const list_top = top_bar_height + @max(16, @floor((avail_h - total_list_h) / 2));
        const list_x = @round((width - list_width) / 2);
        const nl_w: f64 = 120;
        const not_listed: raster.Rect = .{
            .x = @round((width - nl_w) / 2),
            .y = list_top + rows_h + (if (user_count > 0) not_listed_gap else 0),
            .width = nl_w,
            .height = not_listed_height,
        };

        const prompt_block = prompt_avatar_size + 16 + 26 + 24 + entry_height + 14 + 20;
        const prompt_top = top_bar_height + @max(16, @min(@floor((avail_h - prompt_block) / 2) - 16, avail_h - prompt_block - 16));
        const row_y = prompt_top + prompt_avatar_size + 16 + 26 + 24;
        const entry_x = @round((width - entry_width) / 2);
        return .{
            .width = width,
            .height = height,
            .user_count = user_count,
            .power_button = power_button,
            .power_menu = power_menu,
            .power_items = power_items,
            .list_top = list_top,
            .list_x = list_x,
            .not_listed = not_listed,
            .prompt_top = prompt_top,
            .back = .{ .x = entry_x - row_spacing - button_size, .y = row_y, .width = button_size, .height = button_size },
            .entry = .{ .x = entry_x, .y = row_y, .width = entry_width, .height = entry_height },
            .submit = .{ .x = entry_x + entry_width + row_spacing, .y = row_y, .width = button_size, .height = button_size },
        };
    }

    pub fn userRow(self: Layout, index: usize) raster.Rect {
        return .{
            .x = self.list_x,
            .y = self.list_top + @as(f64, @floatFromInt(index)) * (user_row_height + user_row_gap),
            .width = list_width,
            .height = user_row_height,
        };
    }

    pub fn hitTest(self: Layout, frame: Frame, x: f64, y: f64) Target {
        if (self.power_button.contains(x, y)) return .power_button;
        if (frame.power_menu_open) {
            const actions = [_]PowerAction{ .@"suspend", .reboot, .poweroff };
            for (self.power_items, actions) |rect, action| {
                if (rect.contains(x, y)) return .{ .power_action = action };
            }
            return .none;
        }
        switch (frame.stage) {
            .user_list => {
                for (0..self.user_count) |i| {
                    if (self.userRow(i).contains(x, y)) return .{ .user = i };
                }
                if (self.not_listed.contains(x, y)) return .not_listed;
            },
            .username, .password => {
                if (self.back.contains(x, y)) return .back;
                if (self.entry.contains(x, y)) return .entry;
                if (self.submit.contains(x, y)) return .submit;
            },
        }
        return .none;
    }
};

const CachedUser = struct {
    display_name: ?[:0]u8 = null,
    avatar: ?decode.Image = null,
    list_mask: ?text.Mask = null,
    prompt_mask: ?text.Mask = null,
};

pub const View = struct {
    allocator: std.mem.Allocator,
    renderer: text.Renderer = .{},
    users: []CachedUser = &.{},
    clock_text: [64:0]u8 = @splat(0),
    masks: [static_label_count]?text.Mask = @splat(null),
    power_icon: ?decode.Image = null,
    custom_text_buf: [256:0]u8 = @splat(0),
    custom_text_len: usize = 0,
    custom_entry_mask: ?text.Mask = null,
    custom_title_mask: ?text.Mask = null,
    scale: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, entries: []const UserEntry) !View {
        var self: View = .{ .allocator = allocator };
        errdefer self.deinit();
        const cached = try allocator.alloc(CachedUser, entries.len);
        for (cached) |*slot| slot.* = .{};
        self.users = cached;
        for (entries, cached) |entry, *slot| {
            slot.display_name = try allocator.dupeSentinel(u8, entry.display_name, 0);
            if (entry.avatar_path) |path| slot.avatar = decode.file(allocator, path, @intFromFloat(prompt_avatar_size * 4));
        }
        _ = self.tick();
        try self.prepare(1);
        return self;
    }

    pub fn deinit(self: *View) void {
        self.releaseMasks();
        for (self.users) |user| {
            if (user.avatar) |image| decode.free(self.allocator, image);
            if (user.display_name) |name| self.allocator.free(name);
        }
        if (self.users.len > 0) self.allocator.free(self.users);
        self.renderer.deinit();
        self.* = undefined;
    }

    fn releaseMasks(self: *View) void {
        for (&self.masks) |*slot| {
            if (slot.*) |mask| mask.deinit(self.allocator);
            slot.* = null;
        }
        for (self.users) |*user| {
            if (user.list_mask) |mask| mask.deinit(self.allocator);
            if (user.prompt_mask) |mask| mask.deinit(self.allocator);
            user.list_mask = null;
            user.prompt_mask = null;
        }
        if (self.power_icon) |icon| decode.free(self.allocator, icon);
        self.power_icon = null;
        if (self.custom_entry_mask) |mask| mask.deinit(self.allocator);
        self.custom_entry_mask = null;
        if (self.custom_title_mask) |mask| mask.deinit(self.allocator);
        self.custom_title_mask = null;
        self.custom_text_len = 0;
    }

    pub fn tick(self: *View) bool {
        const now = c.g_date_time_new_now_local() orelse return false;
        defer c.g_date_time_unref(now);
        const value = c.g_date_time_format(now, "%a %b %-d %H:%M") orelse return false;
        defer c.g_free(value);
        const formatted = std.mem.span(value);
        if (formatted.len >= self.clock_text.len) return false;
        if (std.mem.eql(u8, std.mem.sliceTo(&self.clock_text, 0), formatted)) return false;
        @memset(&self.clock_text, 0);
        @memcpy(self.clock_text[0..formatted.len], formatted);
        if (self.scale != 0) {
            if (self.masks[@intFromEnum(StaticLabel.clock)]) |mask| mask.deinit(self.allocator);
            self.masks[@intFromEnum(StaticLabel.clock)] = null;
            self.renderStaticLabels(self.scale);
        }
        return true;
    }

    fn prepare(self: *View, scale: u32) !void {
        if (self.scale == scale) return;
        self.releaseMasks();
        self.scale = scale;
        self.renderStaticLabels(scale);
        const factor: f64 = @floatFromInt(scale);
        for (self.users) |*user| {
            const name = user.display_name orelse continue;
            if (name.len == 0) continue;
            user.list_mask = self.renderer.renderLayout(self.allocator, name, .{
                .font = "Adwaita Sans Bold",
                .size = 16 * factor,
                .dpi = 96 * factor,
                .origin = .top,
            }) catch null;
            user.prompt_mask = self.renderer.renderLayout(self.allocator, name, .{
                .font = "Adwaita Sans Extra-Bold",
                .size = 20 * factor,
                .dpi = 96 * factor,
                .origin = .top,
            }) catch null;
        }
        self.power_icon = icons.load(self.allocator, "system-shutdown-symbolic", 16, scale, icons.white);
    }

    fn renderStaticLabels(self: *View, scale: u32) void {
        const factor: f64 = @floatFromInt(scale);
        for (&self.masks, 0..) |*slot, i| {
            if (slot.* != null) continue;
            const label: StaticLabel = @enumFromInt(i);
            const value: [:0]const u8 = switch (label) {
                .clock => std.mem.sliceTo(&self.clock_text, 0),
                .not_listed => "Not listed?",
                .username_title => "Username",
                .username_placeholder => "Username",
                .password_placeholder => "Password",
                .failed => "Sorry, password authentication didn’t work. Please try again.",
                .caps => "Caps lock is on.",
                .@"suspend" => "Suspend",
                .restart => "Restart…",
                .power_off => "Power Off…",
            };
            if (value.len == 0) continue;
            const font: [:0]const u8, const size: f64 = switch (label) {
                .clock => .{ "Adwaita Sans Bold", 14.667 },
                .username_title => .{ "Adwaita Sans Extra-Bold", 20 },
                .not_listed => .{ "Adwaita Sans", 13.333 },
                .@"suspend", .restart, .power_off => .{ "Adwaita Sans", 14 },
                else => .{ "Adwaita Sans", 14.667 },
            };
            slot.* = self.renderer.renderLayout(self.allocator, value, .{
                .font = font,
                .size = size * factor,
                .dpi = 96 * factor,
                .origin = .top,
            }) catch null;
        }
    }

    fn syncCustomText(self: *View, value: []const u8) void {
        const clamped = value[0..@min(value.len, self.custom_text_buf.len)];
        if (clamped.len == self.custom_text_len and std.mem.eql(u8, self.custom_text_buf[0..self.custom_text_len], clamped)) return;
        if (self.custom_entry_mask) |mask| mask.deinit(self.allocator);
        if (self.custom_title_mask) |mask| mask.deinit(self.allocator);
        self.custom_entry_mask = null;
        self.custom_title_mask = null;
        @memset(&self.custom_text_buf, 0);
        @memcpy(self.custom_text_buf[0..clamped.len], clamped);
        self.custom_text_len = clamped.len;
        if (clamped.len == 0 or self.scale == 0) return;
        const factor: f64 = @floatFromInt(self.scale);
        const slice: [:0]const u8 = self.custom_text_buf[0..clamped.len :0];
        self.custom_entry_mask = self.renderer.renderLayout(self.allocator, slice, .{
            .font = "Adwaita Sans",
            .size = 14.667 * factor,
            .dpi = 96 * factor,
            .origin = .top,
        }) catch null;
        self.custom_title_mask = self.renderer.renderLayout(self.allocator, slice, .{
            .font = "Adwaita Sans Extra-Bold",
            .size = 20 * factor,
            .dpi = 96 * factor,
            .origin = .top,
        }) catch null;
    }

    fn maskExtent(self: *const View, mask: ?text.Mask) [2]f64 {
        const value = mask orelse return .{ 0, 0 };
        const factor: f64 = @floatFromInt(self.scale);
        const w = if (value.logical_width != 0) value.logical_width else value.width;
        const h = if (value.logical_height != 0) value.logical_height else value.height;
        return .{ @as(f64, @floatFromInt(w)) / factor, @as(f64, @floatFromInt(h)) / factor };
    }

    fn paintCenteredMask(self: *const View, canvas: raster.Canvas, mask: ?text.Mask, width: f64, y: f64, color: raster.Color) f64 {
        const size = self.maskExtent(mask);
        if (mask) |m| m.paint(canvas, @round((width - size[0]) / 2), @round(y), color);
        return size[1];
    }

    pub fn paintSecondary(target: raster.Buffer) void {
        raster.fill(target, .{ .x = 0, .y = 0, .width = target.width, .height = target.height }, background_pixel, .source);
    }

    pub fn paint(self: *View, target: raster.Buffer, scale: u32, frame: Frame) void {
        self.prepare(scale) catch {};
        self.syncCustomText(frame.username_text);
        raster.fill(target, .{ .x = 0, .y = 0, .width = target.width, .height = target.height }, background_pixel, .source);
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        const width = @as(f64, @floatFromInt(target.width)) / canvas.scale;
        const height = @as(f64, @floatFromInt(target.height)) / canvas.scale;
        const layout = Layout.compute(width, height, self.users.len);

        self.paintTopBar(canvas, layout, frame);
        switch (frame.stage) {
            .user_list => self.paintUserList(canvas, layout, frame),
            .username, .password => self.paintPrompt(canvas, layout, frame),
        }
        if (frame.power_menu_open) self.paintPowerMenu(canvas, layout, frame);
    }

    fn paintTopBar(self: *const View, canvas: raster.Canvas, layout: Layout, frame: Frame) void {
        const white = raster.hex(0xffffff);
        const clock_mask = self.masks[@intFromEnum(StaticLabel.clock)];
        const clock_size = self.maskExtent(clock_mask);
        if (clock_mask) |m| m.paint(canvas, @round((layout.width - clock_size[0]) / 2), @round((top_bar_height - clock_size[1]) / 2), white);

        const pill = layout.power_button;
        const pill_hover = frame.hover == .power_button;
        if (frame.power_menu_open or pill_hover) {
            const alpha: f64 = if (frame.power_menu_open) 0.18 else 0.12;
            canvas.draw(&.{pill.shape(power_pill_height / 2)}, raster.Color.rgb(0xffffff, alpha));
        }
        const ix = pill.x + (pill.width - 16) / 2;
        const iy = pill.y + (pill.height - 16) / 2;
        if (self.power_icon) |icon| {
            c.__zig.blitImage(canvas, icon, .{ .x = ix, .y = iy, .width = 16, .height = 16 });
        } else {
            // Crisp fallback power symbol when icon theme is absent in unit tests.
            const cx = pill.x + pill.width / 2;
            const cy = pill.y + pill.height / 2;
            canvas.draw(&.{
                .{ .arc = .{ .center = .{ .x = cx, .y = cy + 0.5 }, .radius = 5.5, .start = -std.math.pi * 0.28, .end = std.math.pi * 1.28, .stroke = 1.6 } },
                .{ .line = .{ .start = .{ .x = cx, .y = cy - 6.5 }, .end = .{ .x = cx, .y = cy - 0.5 }, .radius = 0.8 } },
            }, white);
        }
    }

    fn paintPowerMenu(self: *const View, canvas: raster.Canvas, layout: Layout, frame: Frame) void {
        const menu = layout.power_menu;
        canvas.draw(&.{menu.shape(14)}, raster.hex(popover_bg));
        canvas.draw(&.{menu.stroke(14, 1)}, raster.Color.rgb(0xffffff, 0.08));
        const labels = [_]StaticLabel{ .@"suspend", .restart, .power_off };
        const actions = [_]PowerAction{ .@"suspend", .reboot, .poweroff };
        const white = raster.hex(0xffffff);
        for (layout.power_items, labels, actions) |rect, label, action| {
            const hovered = switch (frame.hover) {
                .power_action => |a| a == action,
                else => false,
            };
            if (hovered) canvas.draw(&.{rect.shape(8)}, raster.Color.rgb(0xffffff, 0.10));
            const mask = self.masks[@intFromEnum(label)];
            const size = self.maskExtent(mask);
            if (mask) |m| m.paint(canvas, rect.x + 12, @round(rect.y + (rect.height - size[1]) / 2), white);
        }
    }

    fn paintUserList(self: *const View, canvas: raster.Canvas, layout: Layout, frame: Frame) void {
        const white = raster.hex(0xffffff);
        for (self.users, 0..) |user, i| {
            const row = layout.userRow(i);
            const selected = frame.selected == i;
            const hovered = switch (frame.hover) {
                .user => |idx| idx == i,
                else => false,
            };
            const bg_alpha: f64 = if (selected) 0.14 else if (hovered) 0.11 else 0.05;
            canvas.draw(&.{row.shape(user_row_radius)}, raster.Color.rgb(0xffffff, bg_alpha));
            if (selected) {
                const ring: raster.Rect = .{ .x = row.x + 1, .y = row.y + 1, .width = row.width - 2, .height = row.height - 2 };
                canvas.draw(&.{ring.stroke(user_row_radius - 1, 2)}, raster.Color.rgb(accent, 0.7));
            }
            paintAvatar(canvas, user.avatar, row.x + 12 + list_avatar_size / 2, row.y + user_row_height / 2, list_avatar_size);
            const size = self.maskExtent(user.list_mask);
            if (user.list_mask) |m| m.paint(canvas, row.x + 12 + list_avatar_size + 14, @round(row.y + (row.height - size[1]) / 2), white);
        }

        const nl = layout.not_listed;
        const nl_selected = frame.selected == self.users.len;
        const nl_hovered = frame.hover == .not_listed;
        if (nl_selected or nl_hovered) {
            canvas.draw(&.{nl.shape(not_listed_height / 2)}, raster.Color.rgb(0xffffff, if (nl_selected) 0.14 else 0.08));
        }
        if (nl_selected) {
            const ring: raster.Rect = .{ .x = nl.x + 1, .y = nl.y + 1, .width = nl.width - 2, .height = nl.height - 2 };
            canvas.draw(&.{ring.stroke(not_listed_height / 2 - 1, 2)}, raster.Color.rgb(accent, 0.7));
        }
        const nl_mask = self.masks[@intFromEnum(StaticLabel.not_listed)];
        const nl_size = self.maskExtent(nl_mask);
        if (nl_mask) |m| m.paint(canvas, @round(nl.x + (nl.width - nl_size[0]) / 2), @round(nl.y + (nl.height - nl_size[1]) / 2), raster.Color.rgb(0xffffff, if (nl_selected or nl_hovered) 1.0 else 0.7));
    }

    fn paintPrompt(self: *const View, canvas: raster.Canvas, layout: Layout, frame: Frame) void {
        const white = raster.hex(0xffffff);
        const busy = frame.status == .authenticating;
        const active_user: ?CachedUser = if (frame.stage == .password and frame.active_user != null and frame.active_user.? < self.users.len)
            self.users[frame.active_user.?]
        else
            null;

        paintAvatar(canvas, if (active_user) |u| u.avatar else null, layout.width / 2, layout.prompt_top + prompt_avatar_size / 2, prompt_avatar_size);

        const title_mask: ?text.Mask = if (frame.stage == .username)
            self.masks[@intFromEnum(StaticLabel.username_title)]
        else if (active_user) |u|
            u.prompt_mask
        else
            self.custom_title_mask;
        _ = self.paintCenteredMask(canvas, title_mask, layout.width, layout.prompt_top + prompt_avatar_size + 16, white);

        const row_y = layout.entry.y;
        const center_y = row_y + entry_height / 2;

        // Back button (left of entry).
        const back = layout.back;
        const bx = back.x + button_size / 2;
        const back_alpha: f64 = if (busy) 0.05 else if (frame.hover == .back) 0.18 else 0.10;
        canvas.draw(&.{back.shape(button_size / 2)}, raster.Color.rgb(0xffffff, back_alpha));
        const chevron = [_]raster.Shape{
            .{ .line = .{ .start = .{ .x = bx + 2.5, .y = center_y - 5 }, .end = .{ .x = bx - 2.5, .y = center_y }, .radius = 1 } },
            .{ .line = .{ .start = .{ .x = bx - 2.5, .y = center_y }, .end = .{ .x = bx + 2.5, .y = center_y + 5 }, .radius = 1 } },
        };
        canvas.draw(&chevron, raster.Color.rgb(0xffffff, if (busy) 0.4 else 0.9));

        // Pill entry with GNOME's focus ring.
        const entry = layout.entry;
        canvas.draw(&.{entry.shape(entry_height / 2)}, raster.Color.rgb(0xffffff, if (busy) 0.05 else 0.10));
        if (!busy) {
            const ring: raster.Rect = .{ .x = entry.x + 1, .y = entry.y + 1, .width = entry.width - 2, .height = entry.height - 2 };
            canvas.draw(&.{ring.stroke(entry_height / 2 - 1, 2)}, raster.Color.rgb(accent, 0.65));
        }

        const content = raster.Color.rgb(0xffffff, if (busy) 0.5 else 1.0);
        if (frame.stage == .username) {
            if (self.custom_text_len == 0) {
                const ph = self.masks[@intFromEnum(StaticLabel.username_placeholder)];
                if (ph) |m| m.paint(canvas, entry.x + 16, @round(center_y - self.maskExtent(ph)[1] / 2), raster.Color.rgb(0xffffff, 0.5));
            } else if (self.custom_entry_mask) |m| {
                const ext = self.maskExtent(m);
                m.paint(canvas, entry.x + 16, @round(center_y - ext[1] / 2), content);
            }
            const caret_x = @min(entry.x + entry.width - 14, entry.x + 16 + self.maskExtent(self.custom_entry_mask)[0] + 1);
            canvas.draw(&.{.{ .line = .{ .start = .{ .x = caret_x, .y = center_y - 9 }, .end = .{ .x = caret_x, .y = center_y + 9 }, .radius = 0.5 } }}, content);
        } else {
            const dots: usize = @min(frame.typed, max_dots);
            if (dots == 0 and !busy) {
                const ph = self.masks[@intFromEnum(StaticLabel.password_placeholder)];
                if (ph) |m| m.paint(canvas, entry.x + 16, @round(center_y - self.maskExtent(ph)[1] / 2), raster.Color.rgb(0xffffff, 0.5));
            }
            var shapes: [max_dots + 1]raster.Shape = undefined;
            for (0..dots) |i| shapes[i] = .{ .circle = .{ .center = .{ .x = entry.x + 18 + @as(f64, @floatFromInt(i * dot_spacing)), .y = center_y }, .radius = dot_radius } };
            var count = dots;
            if (!busy) {
                const caret_x = entry.x + 13 + @as(f64, @floatFromInt(dots * dot_spacing));
                shapes[count] = .{ .line = .{ .start = .{ .x = caret_x, .y = center_y - 9 }, .end = .{ .x = caret_x, .y = center_y + 9 }, .radius = 0.5 } };
                count += 1;
            }
            canvas.draw(shapes[0..count], content);
        }

        // Right well: spinner while authenticating, or circular submit button.
        const submit = layout.submit;
        const sx = submit.x + button_size / 2;
        if (busy) {
            const track: raster.Rect = .{ .x = sx - 8, .y = center_y - 8, .width = 16, .height = 16 };
            canvas.draw(&.{track.stroke(8, 2)}, raster.Color.rgb(0xffffff, 0.15));
            canvas.draw(&.{.{ .arc = .{ .center = .{ .x = sx, .y = center_y }, .radius = 8, .start = frame.spin, .end = frame.spin + std.math.pi * 0.75, .stroke = 2 } }}, raster.Color.rgb(0xffffff, 0.9));
        } else {
            const can_submit = if (frame.stage == .username) self.custom_text_len > 0 else frame.typed > 0;
            const sub_alpha: f64 = if (!can_submit) 0.05 else if (frame.hover == .submit) 0.20 else 0.12;
            canvas.draw(&.{submit.shape(button_size / 2)}, raster.Color.rgb(0xffffff, sub_alpha));
            const arrow = [_]raster.Shape{
                .{ .line = .{ .start = .{ .x = sx - 5, .y = center_y }, .end = .{ .x = sx + 5, .y = center_y }, .radius = 1 } },
                .{ .line = .{ .start = .{ .x = sx + 0.5, .y = center_y - 4.5 }, .end = .{ .x = sx + 5, .y = center_y }, .radius = 1 } },
                .{ .line = .{ .start = .{ .x = sx + 0.5, .y = center_y + 4.5 }, .end = .{ .x = sx + 5, .y = center_y }, .radius = 1 } },
            };
            canvas.draw(&arrow, raster.Color.rgb(0xffffff, if (can_submit) 0.95 else 0.35));
        }

        const msg_label: ?StaticLabel = if (frame.status == .failed)
            .failed
        else if (frame.stage == .password and frame.caps_lock)
            .caps
        else
            null;
        if (msg_label) |label| {
            _ = self.paintCenteredMask(canvas, self.masks[@intFromEnum(label)], layout.width, row_y + entry_height + 14, raster.hex(warning));
        }
    }
};

fn paintAvatar(canvas: raster.Canvas, avatar: ?decode.Image, cx: f64, cy: f64, size: f64) void {
    const radius = size / 2;
    if (avatar) |image| {
        const s = canvas.scale;
        const rect: raster.Rect = .{ .x = (cx - radius) * s, .y = (cy - radius) * s, .width = size * s, .height = size * s };
        const clip: raster.Shape = .{ .circle = .{ .center = .{ .x = cx * s, .y = cy * s }, .radius = radius * s } };
        if (raster.blitWithOptions(canvas.target, image.view(), rect, .{ .shape = clip })) return else |_| {}
    }
    const k = size / 128.0;
    canvas.draw(&.{.{ .circle = .{ .center = .{ .x = cx, .y = cy }, .radius = radius } }}, raster.Color.rgb(0xffffff, 0.12));
    var body: [25]raster.Point = undefined;
    for (&body, 0..) |*point, i| {
        const angle = std.math.pi * @as(f64, @floatFromInt(i)) / 24;
        point.* = .{ .x = cx - 34 * k * @cos(angle), .y = cy + 38 * k - 30 * k * @sin(angle) };
    }
    canvas.draw(&.{.{ .polygon = &body }}, raster.Color.rgb(0xffffff, 0.8));
    canvas.draw(&.{.{ .circle = .{ .center = .{ .x = cx, .y = cy - 12 * k }, .radius = 17 * k } }}, raster.Color.rgb(0xffffff, 0.8));
}

test "greeter view renders every stage, status, scale, and power menu safely" {
    const allocator = std.testing.allocator;
    var view = try View.init(allocator, &.{
        .{ .username = "alice", .display_name = "Alice Example" },
        .{ .username = "bob", .display_name = "Bob Example" },
    });
    defer view.deinit();
    for ([_][2]u32{ .{ 1280, 800 }, .{ 40, 30 } }) |size| for ([_]u32{ 1, 2 }) |scale| {
        const count = size[0] * size[1] * scale * scale;
        const storage = try allocator.alloc(u32, count + 2);
        defer allocator.free(storage);
        const target: raster.Buffer = .{ .pixels = storage[1 .. count + 1], .width = size[0] * scale, .height = size[1] * scale };
        for ([_]Stage{ .user_list, .username, .password }) |stage| for ([_]Status{ .ready, .authenticating, .failed }) |status| {
            @memset(storage, 0x12345678);
            view.paint(target, scale, .{
                .stage = stage,
                .status = status,
                .selected = 0,
                .active_user = 0,
                .username_text = "charlie",
                .typed = 6,
                .caps_lock = true,
                .spin = 1.2,
                .power_menu_open = status == .ready,
            });
            for (target.pixels) |pixel| try std.testing.expectEqual(@as(u32, 255), pixel >> 24);
            try std.testing.expectEqual(@as(u32, 0x12345678), storage[0]);
            try std.testing.expectEqual(@as(u32, 0x12345678), storage[count + 1]);
            if (size[0] > 100) {
                var foreground: usize = 0;
                for (target.pixels) |pixel| foreground += @intFromBool(pixel != background_pixel);
                try std.testing.expect(foreground > 200 * scale * scale);
            }
        };
    };
}

test "greeter layout hit-tests user list, prompt buttons, and power menu" {
    const layout = Layout.compute(1280, 800, 2);
    const list_frame: Frame = .{ .stage = .user_list };
    const row0 = layout.userRow(0);
    try std.testing.expectEqual(Target{ .user = 0 }, layout.hitTest(list_frame, row0.x + 10, row0.y + 10));
    try std.testing.expectEqual(Target.not_listed, layout.hitTest(list_frame, layout.not_listed.x + 5, layout.not_listed.y + 5));
    try std.testing.expectEqual(Target.power_button, layout.hitTest(list_frame, layout.power_button.x + 5, layout.power_button.y + 5));

    const menu_frame: Frame = .{ .stage = .user_list, .power_menu_open = true };
    try std.testing.expectEqual(Target{ .power_action = .@"suspend" }, layout.hitTest(menu_frame, layout.power_items[0].x + 5, layout.power_items[0].y + 5));
    try std.testing.expectEqual(Target{ .power_action = .reboot }, layout.hitTest(menu_frame, layout.power_items[1].x + 5, layout.power_items[1].y + 5));
    try std.testing.expectEqual(Target{ .power_action = .poweroff }, layout.hitTest(menu_frame, layout.power_items[2].x + 5, layout.power_items[2].y + 5));
    // While the power menu is open, clicking a user row underneath dismisses rather than selecting.
    try std.testing.expectEqual(Target.none, layout.hitTest(menu_frame, row0.x + 10, row0.y + 10));

    const prompt_frame: Frame = .{ .stage = .password };
    try std.testing.expectEqual(Target.back, layout.hitTest(prompt_frame, layout.back.x + 5, layout.back.y + 5));
    try std.testing.expectEqual(Target.entry, layout.hitTest(prompt_frame, layout.entry.x + 5, layout.entry.y + 5));
    try std.testing.expectEqual(Target.submit, layout.hitTest(prompt_frame, layout.submit.x + 5, layout.submit.y + 5));
}
