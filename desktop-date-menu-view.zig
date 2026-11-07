//! Calendar geometry and native notification history, sharing banner rendering.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
pub const banner = @import("desktop-notification-banner.zig");
const data = @import("desktop-notification-view.zig");
pub const Rect = @import("desktop-askpass-view.zig").Rect;
pub const NoticeTarget = struct { id: u32, part: banner.Target };
pub const Target = union(enum) { none, today, previous, month, next, day: usize, clear, scrollbar, notice: NoticeTarget };
pub const Effect = union(enum) { none, clear, dismiss: u32, activate: struct { id: u32, key: [:0]const u8 } };
const Card = struct { view: banner.View, y: f64 = 0 };
const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    cards: std.ArrayList(Card) = .empty,
    fn deinit(self: *Snapshot, a: std.mem.Allocator) void {
        for (self.cards.items) |*card| card.view.deinit();
        self.cards.deinit(a);
        self.arena.deinit();
    }
};
pub const View = struct {
    allocator: std.mem.Allocator,
    selected: *c.GDateTime,
    days: [42]?*c.GDateTime = @splat(null),
    snapshot: Snapshot,
    width: u32 = 752,
    height: u32 = 420,
    scale: u32 = 0,
    minute: i64 = -1,
    scroll: f64 = 0,
    history_height: f64 = 0,
    hover: Target = .none,
    pressed: Target = .none,
    focus: Target = .month,
    keyboard_focus: bool = true,
    renderer: text.Renderer = .{},
    masks: [54]?text.Mask = @splat(null),
    targets: std.ArrayList(Target) = .empty,
    scratch: std.ArrayList(u32) = .empty,

    pub fn init(a: std.mem.Allocator) !View {
        return .{ .allocator = a, .selected = c.g_date_time_new_now_local() orelse return error.DateUnavailable, .snapshot = .{ .arena = std.heap.ArenaAllocator.init(a) } };
    }
    pub fn deinit(self: *View) void {
        self.invalidate();
        self.renderer.deinit();
        for (self.days) |day| if (day) |value| c.g_date_time_unref(value);
        c.g_date_time_unref(self.selected);
        self.snapshot.deinit(self.allocator);
        self.targets.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
    }
    fn invalidate(self: *View) void {
        for (&self.masks) |*mask| {
            if (mask.*) |value| value.deinit(self.allocator);
            mask.* = null;
        }
        self.scale = 0;
    }
    pub fn setDate(self: *View, value: *c.GDateTime) void {
        c.g_date_time_unref(self.selected);
        self.selected = value;
        self.invalidate();
    }
    pub fn navigate(self: *View, months: c_int) void {
        const value = if (months == 0) c.g_date_time_new_now_local() else c.g_date_time_add_months(self.selected, months);
        if (value) |day| self.setDate(day);
    }
    pub fn selectDay(self: *View, index: usize) void {
        if (index >= self.days.len) return;
        if (self.days[index]) |day| self.setDate(c.g_date_time_ref(day).?);
    }
    pub fn selectedIndex(self: *const View) usize {
        for (self.days, 0..) |day, i| if (day != null and sameDate(day, self.selected)) return i;
        return 0;
    }
    pub fn historyRect(_: *const View) Rect {
        return .{ .x = 8, .y = 8, .width = 424, .height = 352 };
    }
    pub fn rect(self: *const View, target: Target) Rect {
        return switch (target) {
            .today => .{ .x = 460, .y = 10, .width = 280, .height = 64 },
            .previous => .{ .x = 460, .y = 94, .width = 40, .height = 38 },
            .month => .{ .x = 500, .y = 94, .width = 200, .height = 38 },
            .next => .{ .x = 700, .y = 94, .width = 40, .height = 38 },
            .day => |i| .{ .x = 462 + @as(f64, @floatFromInt(i % 7 * 40)), .y = 173 + @as(f64, @floatFromInt(i / 7 * 36)), .width = 36, .height = 36 },
            .clear => .{ .x = 16, .y = 374, .width = 80, .height = 34 },
            .scrollbar => self.scrollbarRect(),
            .notice => |notice| blk: {
                const card = self.cardById(notice.id) orelse break :blk zero_rect;
                if (!card.view.targetVisible(notice.part)) break :blk zero_rect;
                const part = card.view.targetRect(notice.part);
                break :blk .{ .x = 8 + part.x, .y = 8 + card.y - self.scroll + part.y, .width = part.width, .height = part.height };
            },
            .none => zero_rect,
        };
    }
    pub fn scrollbarRect(self: *const View) Rect {
        const area = self.historyRect();
        if (self.history_height <= area.height) return zero_rect;
        const height = @max(24, area.height * area.height / self.history_height);
        return .{ .x = 434, .y = area.y + (area.height - height) * self.scroll / (self.history_height - area.height), .width = 4, .height = height };
    }
    pub fn dragScroll(self: *View, y: f64, grab: f64) void {
        if (!std.math.isFinite(y) or !std.math.isFinite(grab)) return;
        const area = self.historyRect();
        const thumb = self.scrollbarRect();
        if (thumb.height == 0) return;
        const fraction = std.math.clamp((y - area.y - grab) / (area.height - thumb.height), 0, 1);
        self.scrollBy(fraction * (self.history_height - area.height) - self.scroll);
    }
    fn cardById(self: *const View, id: u32) ?*Card {
        for (self.snapshot.cards.items) |*card| if (card.view.notice.id == id) return card;
        return null;
    }
    pub fn count(self: *const View) usize {
        return self.snapshot.cards.items.len;
    }
    pub fn load(self: *View, raw: []const u8) !void {
        // Commit only a fully parsed, prepared snapshot. Existing cards own the
        // strings referenced by their masks and callbacks until replacement.
        var next: Snapshot = .{ .arena = std.heap.ArenaAllocator.init(self.allocator) };
        errdefer next.deinit(self.allocator);
        const a = next.arena.allocator();
        const parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
        if (parsed.value != .array) return error.InvalidHistory;
        var i = parsed.value.array.items.len;
        while (i > 0) {
            i -= 1;
            const item = parsed.value.array.items[i];
            if (item != .object) continue;
            const id_value = item.object.get("id") orelse continue;
            const created = item.object.get("created") orelse continue;
            if (id_value != .integer or created != .integer) continue;
            if (created.integer < 0) continue;
            const id = std.math.cast(u32, id_value.integer) orelse continue;
            var duplicate = false;
            for (next.cards.items) |card| if (card.view.notice.id == id) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            var actions: std.ArrayList(data.Action) = .empty;
            if (item.object.get("actions")) |values| if (values == .array) {
                for (values.array.items) |action| {
                    if (actions.items.len == 32) break;
                    if (action != .object) continue;
                    try actions.append(a, .{ .key = try jsonString(a, action.object.get("key")), .label = try jsonString(a, action.object.get("label")) });
                }
            };
            var view = banner.View.init(.{
                .id = id,
                .created = created.integer,
                .app = try jsonString(a, item.object.get("app")),
                .title = try jsonString(a, item.object.get("title")),
                .body = try jsonString(a, item.object.get("body")),
                .icon = try jsonString(a, item.object.get("icon")),
                .actions = actions.items,
            }, .{}, 424);
            errdefer view.deinit();
            view.history = true;
            if (self.cardById(id)) |old| view.expanded = old.view.expanded;
            try view.prepare(@max(1, self.scale));
            try next.cards.append(self.allocator, .{ .view = view });
        }
        self.snapshot.deinit(self.allocator);
        self.snapshot = next;
        next = .{ .arena = std.heap.ArenaAllocator.init(self.allocator) };
        self.pressed = .none;
        self.hover = .none;
        try self.layout();
        self.ensureFocusVisible();
    }
    pub fn prepare(self: *View, scale: u32) !void {
        const minute = @divTrunc(c.g_get_real_time(), 60_000_000);
        if (minute != self.minute) {
            self.minute = minute;
            self.invalidate();
            for (self.snapshot.cards.items) |*card| card.view.invalidate();
        }
        if (self.scale != scale) {
            self.invalidate();
            errdefer self.invalidate();
            const now = c.g_date_time_new_now_local() orelse return error.DateUnavailable;
            defer c.g_date_time_unref(now);
            try self.dateLabel(0, now, "%A", 14.666, true, 260, scale);
            try self.dateLabel(1, now, "%B %-d %Y", 20, true, 260, scale);
            try self.dateLabel(2, self.selected, if (c.g_date_time_get_year(now) == c.g_date_time_get_year(self.selected)) "%B" else "%B %Y", 14.666, true, 192, scale);
            const first = c.g_date_time_add_days(self.selected, 1 - c.g_date_time_get_day_of_month(self.selected)) orelse return error.DateUnavailable;
            defer c.g_date_time_unref(first);
            const start = c.g_date_time_add_days(first, -@mod(c.g_date_time_get_day_of_week(first), 7)) orelse return error.DateUnavailable;
            defer c.g_date_time_unref(start);
            for (&self.days, 0..) |*slot, i| {
                if (slot.*) |old| c.g_date_time_unref(old);
                slot.* = c.g_date_time_add_days(start, @intCast(i));
                if (slot.* == null) return error.DateUnavailable;
                try self.dateLabel(10 + i, slot.*, "%d", 12, true, 36, scale);
                if (i < 7) {
                    const name = c.g_date_time_format(slot.*, "%a");
                    defer c.g_free(name);
                    const end = c.g_utf8_offset_to_pointer(name, 1);
                    const letter = try self.allocator.dupeSentinel(u8, name[0 .. @intFromPtr(end) - @intFromPtr(name)], 0);
                    defer self.allocator.free(letter);
                    try self.label(3 + i, letter, 12, true, 36, scale);
                }
            }
            try self.label(52, "Clear", 14.666, true, 80, scale);
            try self.label(53, "No Notifications", 20, true, 400, scale);
            self.scale = scale;
        }
        for (self.snapshot.cards.items) |*card| try card.view.prepare(scale);
        try self.layout();
    }
    fn dateLabel(self: *View, index: usize, day: ?*c.GDateTime, format: [:0]const u8, size: f64, bold: bool, width: u32, scale: u32) !void {
        const value = c.g_date_time_format(day, format);
        if (value == null) return error.DateUnavailable;
        defer c.g_free(value);
        try self.label(index, std.mem.span(value), size, bold, width, scale);
    }
    fn label(self: *View, index: usize, value: [:0]const u8, size: f64, bold: bool, width: u32, scale: u32) !void {
        self.masks[index] = try self.renderer.renderLayout(self.allocator, value, .{ .font = if (bold) "Adwaita Sans Bold" else "Adwaita Sans", .size = size * @as(f64, @floatFromInt(scale)), .dpi = 96 * @as(f64, @floatFromInt(scale)), .width = width * scale, .ellipsize = true, .origin = .top });
    }
    fn layout(self: *View) !void {
        var y: f64 = 0;
        self.targets.clearRetainingCapacity();
        for (self.snapshot.cards.items) |*card| {
            card.y = y;
            y += @as(f64, @floatFromInt(card.view.height)) + 4;
            for ([_]banner.Target{ .card, .expand, .close, .action0, .action1, .action2 }) |part| if (card.view.targetVisible(part)) {
                try self.targets.append(self.allocator, .{ .notice = .{ .id = card.view.notice.id, .part = part } });
            };
        }
        self.history_height = @max(0, y - 4);
        self.scrollBy(0);
        if (self.history_height > self.historyRect().height) try self.targets.append(self.allocator, .scrollbar);
        if (self.count() != 0) try self.targets.append(self.allocator, .clear);
        for ([_]Target{ .today, .previous, .month, .next }) |target| try self.targets.append(self.allocator, target);
        for (0..42) |i| try self.targets.append(self.allocator, .{ .day = i });
        var found = false;
        for (self.targets.items) |target| if (std.meta.eql(target, self.focus)) {
            found = true;
            break;
        };
        if (!found) self.focus = if (self.count() == 0) .month else .{ .notice = .{ .id = self.snapshot.cards.items[0].view.notice.id, .part = .card } };
    }
    pub fn hit(self: *const View, x: f64, y: f64) Target {
        if (self.history_height > self.historyRect().height and x >= 432 and x < 442 and y >= 8 and y < 360) return .scrollbar;
        if (self.historyRect().contains(x, y)) {
            for (self.snapshot.cards.items) |card| {
                const part = card.view.hit(x - 8, y - 8 + self.scroll - card.y);
                if (part != .none) return .{ .notice = .{ .id = card.view.notice.id, .part = part } };
            }
            return .none;
        }
        for (self.targets.items) |target| {
            if (target == .notice) continue;
            if (self.rect(target).contains(x, y)) return target;
        }
        return .none;
    }
    pub fn scrollBy(self: *View, amount: f64) void {
        if (!std.math.isFinite(amount)) return;
        const scroll = @round(std.math.clamp(self.scroll + amount, 0, @max(0, self.history_height - self.historyRect().height)));
        if (scroll != self.scroll) {
            self.scroll = scroll;
            self.hover = .none;
            self.pressed = .none;
        }
    }
    pub fn stepFocus(self: *View, backward: bool) void {
        if (self.targets.items.len == 0) return;
        var index: usize = 0;
        for (self.targets.items, 0..) |target, i| if (std.meta.eql(target, self.focus)) {
            index = i;
            break;
        };
        self.focus = self.targets.items[(index + (if (backward) self.targets.items.len - 1 else 1)) % self.targets.items.len];
        self.keyboard_focus = true;
        self.ensureFocusVisible();
    }
    pub fn ensureFocusVisible(self: *View) void {
        if (self.focus != .notice) return;
        const area = self.historyRect();
        const region = self.rect(self.focus);
        if (region.y < area.y) self.scrollBy(region.y - area.y) else if (region.y + region.height > area.y + area.height) self.scrollBy(region.y + region.height - area.y - area.height);
    }
    pub fn activate(self: *View, target: Target) !Effect {
        const factor = @max(1, self.scale);
        switch (target) {
            .today, .month => self.navigate(0),
            .previous => self.navigate(-1),
            .next => self.navigate(1),
            .day => |i| self.selectDay(i),
            .clear => if (self.count() != 0) return .clear,
            .notice => |notice| {
                const card = self.cardById(notice.id) orelse return .none;
                if (!card.view.targetVisible(notice.part)) return .none;
                switch (notice.part) {
                    .expand => {
                        card.view.toggle();
                        try card.view.prepare(@max(1, self.scale));
                        try self.layout();
                        self.ensureFocusVisible();
                    },
                    .close => return .{ .dismiss = notice.id },
                    .card => return .{ .activate = .{ .id = notice.id, .key = "default" } },
                    .action0, .action1, .action2 => return .{ .activate = .{ .id = notice.id, .key = card.view.action_keys[@backingInt(notice.part) - @backingInt(banner.Target.action0)].? } },
                    .none => {},
                }
                return .none;
            },
            .none, .scrollbar => return .none,
        }
        try self.prepare(factor);
        if (target == .day) self.focus = .{ .day = self.selectedIndex() };
        return .none;
    }
    pub fn key(self: *View, symbol: u32, shift: bool) !Effect {
        const factor = @max(1, self.scale);
        self.keyboard_focus = true;
        switch (symbol) {
            0xff09, 0xfe20 => self.stepFocus(shift or symbol == 0xfe20),
            0xff0d, 0xff8d, 0x20 => return self.activate(self.focus),
            0xff55, 0xff56 => {
                if (self.focus == .notice or self.focus == .clear or self.focus == .scrollbar) self.scrollBy(if (symbol == 0xff55) -300 else 300) else self.navigate(if (symbol == 0xff55) -1 else 1);
            },
            0xff50 => self.navigate(0),
            0xff51, 0xff53, 0xff52, 0xff54 => {
                if (self.focus == .day) {
                    const offset: c_int = switch (symbol) {
                        0xff51 => -1,
                        0xff53 => 1,
                        0xff52 => -7,
                        else => 7,
                    };
                    const origin = self.days[self.focus.day] orelse self.selected;
                    if (c.g_date_time_add_days(origin, offset)) |day| self.setDate(day);
                    try self.prepare(factor);
                    self.focus = .{ .day = self.selectedIndex() };
                } else self.stepFocus(symbol == 0xff51 or symbol == 0xff52);
            },
            else => {},
        }
        try self.prepare(factor);
        if (self.focus == .day and (symbol == 0xff50 or symbol == 0xff55 or symbol == 0xff56)) self.focus = .{ .day = self.selectedIndex() };
        return .none;
    }
    pub fn paint(self: *View, target: raster.Buffer) !void {
        @memset(target.pixels, 0);
        const scale: f64 = @floatFromInt(self.scale);
        const canvas: raster.Canvas = .{ .target = target, .scale = scale };
        canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = 0, .y = 0, .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) }, .radius = 30 } }}, color(0x36363a));
        canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = 0.5, .y = 0.5, .width = @floatFromInt(self.width - 1), .height = @floatFromInt(self.height - 1) }, .radius = 30, .width = 1 } }}, color(0x545458));
        canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = 444, .y = 8, .width = 1, .height = 404 }, .radius = 0 } }}, color(0x4a4a4e));
        const now = c.g_date_time_new_now_local() orelse return error.DateUnavailable;
        defer c.g_date_time_unref(now);
        self.paintButton(canvas, .today, 14, if (sameDate(now, self.selected)) 0x36363a else 0x3e3e42);
        self.paintLabel(canvas, 0, 470, 20, if (sameDate(now, self.selected)) 0x9b9b9d else 0xffffff);
        self.paintLabel(canvas, 1, 470, 42, if (sameDate(now, self.selected)) 0x9b9b9d else 0xffffff);
        for ([_]Target{ .previous, .month, .next }) |button| self.paintButton(canvas, button, 18, 0x36363a);
        self.center(canvas, 2, self.rect(.month), 0xffffff);
        for ([_]Target{ .previous, .next }, [_]f64{ -1, 1 }) |button, direction| {
            const r = self.rect(button);
            canvas.draw(&.{
                .{ .line = .{ .start = .{ .x = r.x + 20 - direction * 3, .y = r.y + 14 }, .end = .{ .x = r.x + 20 + direction * 2, .y = r.y + 19 }, .radius = 1 } },
                .{ .line = .{ .start = .{ .x = r.x + 20 + direction * 2, .y = r.y + 19 }, .end = .{ .x = r.x + 20 - direction * 3, .y = r.y + 24 }, .radius = 1 } },
            }, color(0xffffff));
        }
        for (0..7) |i| self.center(canvas, 3 + i, .{ .x = 462 + @as(f64, @floatFromInt(i * 40)), .y = 140, .width = 36, .height = 27 }, if (i == 0 or i == 6) 0x9b9b9d else 0xffffff);
        for (self.days, 0..) |day, i| {
            const today = sameDate(day, now);
            self.paintButton(canvas, .{ .day = i }, 18, if (today) 0x3584e4 else if (sameDate(day, self.selected)) 0x4a4a4e else 0x36363a);
            const other = c.g_date_time_get_month(day) != c.g_date_time_get_month(self.selected);
            self.center(canvas, 10 + i, self.rect(.{ .day = i }), if (today) 0xffffff else if (other) 0x858589 else if (i % 7 == 0 or i % 7 == 6) 0x9b9b9d else 0xffffff);
        }
        self.paintButton(canvas, .clear, 18, if (self.count() == 0) 0x404044 else 0x505054);
        self.center(canvas, 52, self.rect(.clear), if (self.count() == 0) 0x929296 else 0xffffff);
        const area = self.historyRect();
        if (self.count() == 0) {
            // Bell outline and strike use the same raster primitives as controls.
            canvas.draw(&.{
                .{ .arc = .{ .center = .{ .x = 220, .y = 137 }, .radius = 30, .start = std.math.pi, .end = 2 * std.math.pi, .stroke = 4 } },
                .{ .line = .{ .start = .{ .x = 190, .y = 137 }, .end = .{ .x = 184, .y = 171 }, .radius = 2 } },
                .{ .line = .{ .start = .{ .x = 250, .y = 137 }, .end = .{ .x = 256, .y = 171 }, .radius = 2 } },
                .{ .line = .{ .start = .{ .x = 184, .y = 171 }, .end = .{ .x = 256, .y = 171 }, .radius = 2 } },
                .{ .circle = .{ .center = .{ .x = 220, .y = 182 }, .radius = 5 } },
                .{ .line = .{ .start = .{ .x = 177, .y = 111 }, .end = .{ .x = 262, .y = 195 }, .radius = 2 } },
            }, color(0x929296));
            self.center(canvas, 53, .{ .x = 8, .y = 214, .width = 424, .height = 36 }, 0x929296);
        }
        for (self.snapshot.cards.items) |*card| {
            const y = area.y + card.y - self.scroll;
            if (y + @as(f64, @floatFromInt(card.view.height)) <= area.y or y >= area.y + area.height) continue;
            const id = card.view.notice.id;
            card.view.hover = if (self.hover == .notice and self.hover.notice.id == id) self.hover.notice.part else .none;
            card.view.pressed = if (self.pressed == .notice and self.pressed.notice.id == id) self.pressed.notice.part else .none;
            const w = card.view.width * self.scale;
            const h = card.view.height * self.scale;
            try self.scratch.resize(self.allocator, w * h);
            @memset(self.scratch.items, 0);
            card.view.paint(.{ .pixels = self.scratch.items, .width = w, .height = h });
            const clipped: raster.Buffer = .{ .pixels = target.pixels[8 * self.scale * target.width .. 360 * self.scale * target.width], .width = target.width, .height = 352 * self.scale };
            try raster.blit(clipped, .{ .pixels = std.mem.sliceAsBytes(self.scratch.items), .width = w, .height = h, .stride = w * 4, .format = .argb }, .{ .x = area.x * scale, .y = (card.y - self.scroll) * scale, .width = @floatFromInt(w), .height = @floatFromInt(h) }, .{ .x = 8 * @as(i32, @intCast(self.scale)), .y = 0, .width = 424 * self.scale, .height = 352 * self.scale });
        }
        if (self.history_height > area.height) {
            const thumb = self.scrollbarRect();
            canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = thumb.x, .y = thumb.y, .width = thumb.width, .height = thumb.height }, .radius = 2 } }}, color(if (self.hover == .scrollbar or self.focus == .scrollbar) 0xb2b2b4 else 0x858589));
        }
        if (self.keyboard_focus and self.focus == .notice) {
            var r = self.rect(self.focus);
            r.y = @max(r.y, area.y);
            r.height = @max(0, @min(self.rect(self.focus).y + self.rect(self.focus).height, area.y + area.height) - r.y);
            if (r.height > 2) focusRing(canvas, r, 10);
        }
    }
    fn paintButton(self: *const View, canvas: raster.Canvas, target: Target, radius: f64, base: u32) void {
        const r = self.rect(target);
        const enabled = target != .clear or self.count() != 0;
        const fill: u32 = if (enabled and std.meta.eql(self.pressed, target) and std.meta.eql(self.hover, target)) 0x606064 else if (enabled and std.meta.eql(self.hover, target)) 0x505054 else base;
        canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height }, .radius = radius } }}, color(fill));
        if (self.keyboard_focus and std.meta.eql(self.focus, target)) focusRing(canvas, r, radius);
    }
    fn center(self: *const View, canvas: raster.Canvas, index: usize, r: Rect, tint: u32) void {
        const value = self.masks[index] orelse return;
        self.paintLabel(canvas, index, r.x + (r.width - @as(f64, @floatFromInt(value.logical_width)) / canvas.scale) / 2, r.y + (r.height - @as(f64, @floatFromInt(value.logical_height)) / canvas.scale) / 2, tint);
    }
    fn paintLabel(self: *const View, canvas: raster.Canvas, index: usize, x: f64, y: f64, tint: u32) void {
        const value = self.masks[index] orelse return;
        value.paint(canvas, x, y, color(tint));
    }
};
const zero_rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
fn focusRing(canvas: raster.Canvas, r: Rect, radius: f64) void {
    canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = r.x + 1, .y = r.y + 1, .width = r.width - 2, .height = r.height - 2 }, .radius = radius, .width = 2 } }}, color(0x99c1f1));
}
fn sameDate(first: ?*c.GDateTime, second: ?*c.GDateTime) bool {
    return first != null and second != null and c.g_date_time_get_year(first) == c.g_date_time_get_year(second) and c.g_date_time_get_day_of_year(first) == c.g_date_time_get_day_of_year(second);
}
fn color(value: u32) raster.Color {
    return raster.Color.rgb(value, 1);
}
fn jsonString(a: std.mem.Allocator, value: ?std.json.Value) ![:0]const u8 {
    if (value) |v| if (v == .string) return a.dupeSentinel(u8, v.string, 0);
    return "";
}

test "native calendar navigates leap days and years with keyboard focus at both scales" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    for ([_]u32{ 1, 2 }) |scale| {
        view.setDate(c.g_date_time_new_local(2024, 2, 29, 12, 0, 0).?);
        try view.prepare(scale);
        try std.testing.expectEqual(@as(usize, 32), view.selectedIndex());
        const march = view.rect(.{ .day = 33 });
        try std.testing.expect(std.meta.eql(Target{ .day = 33 }, view.hit(march.x + 10, march.y + 10)));
        _ = try view.activate(.{ .day = 33 });
        try std.testing.expectEqual(@as(c_int, 3), c.g_date_time_get_month(view.selected));
        try std.testing.expectEqual(@as(c_int, 1), c.g_date_time_get_day_of_month(view.selected));
        _ = try view.key(0xff51, false);
        try std.testing.expectEqual(@as(c_int, 29), c.g_date_time_get_day_of_month(view.selected));
        try std.testing.expectEqual(@as(c_int, 2), c.g_date_time_get_month(view.selected));
        try std.testing.expectEqual(scale, view.scale);
        _ = try view.key(0xff56, false);
        try std.testing.expectEqual(@as(c_int, 3), c.g_date_time_get_month(view.selected));
        try std.testing.expectEqual(view.selectedIndex(), view.focus.day);
        // An arrow moves from the cell reached by Tab, including adjacent months.
        view.focus = .{ .day = 0 };
        const expected = c.g_date_time_add_days(view.days[0], 1).?;
        defer c.g_date_time_unref(expected);
        _ = try view.key(0xff53, false);
        try std.testing.expect(sameDate(expected, view.selected));
        view.setDate(c.g_date_time_new_local(2023, 12, 31, 12, 0, 0).?);
        try view.prepare(scale);
        _ = try view.activate(.next);
        try std.testing.expectEqual(@as(c_int, 2024), c.g_date_time_get_year(view.selected));
        try std.testing.expectEqual(@as(c_int, 31), c.g_date_time_get_day_of_month(view.selected));
        _ = try view.activate(.next);
        try std.testing.expectEqual(@as(c_int, 29), c.g_date_time_get_day_of_month(view.selected));
        view.navigate(12);
        try std.testing.expectEqual(@as(c_int, 28), c.g_date_time_get_day_of_month(view.selected));
        try view.prepare(scale);
        _ = try view.key(0xff50, false);
        const now = c.g_date_time_new_now_local();
        defer c.g_date_time_unref(now);
        try std.testing.expect(sameDate(now, view.selected));
        try std.testing.expectEqual(scale, view.scale);
    }
}
const test_history =
    \\[{"id":1,"created":1,"app":"First","title":"Older","body":"One"},
    \\ {"id":2,"created":2,"app":"Second","title":"Middle","body":"Two"},
    \\ {"id":3,"created":3,"app":"Messages 東京","title":"مرحبا <&>","body":"<b>Long body</b> &amp; 東京 long long long long long long long long long long long long long long long long long long long long long long long long long long", "actions":[{"key":"default","label":"Open"},{"key":"reply","label":"Reply"},{"key":"archive","label":"Archive"}]}]
;
test "native history preserves expansion and focus across snapshots and clips scrolling" {
    c.gtk_init(null, null);
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.prepare(1);
    try view.load(test_history);
    try std.testing.expectEqual(@as(usize, 3), view.count());
    try std.testing.expectEqual(@as(u32, 3), view.snapshot.cards.items[0].view.notice.id);
    view.focus = .{ .notice = .{ .id = 3, .part = .expand } };
    _ = try view.activate(view.focus);
    const action: Target = .{ .notice = .{ .id = 3, .part = .action0 } };
    const activated = try view.activate(action);
    try std.testing.expectEqual(@as(u32, 3), activated.activate.id);
    try std.testing.expectEqualStrings("reply", activated.activate.key);
    view.focus = action;
    try view.load(test_history);
    try std.testing.expect(view.snapshot.cards.items[0].view.expanded);
    try std.testing.expect(std.meta.eql(view.focus, action));
    try std.testing.expectError(error.InvalidHistory, view.load("{}"));
    try std.testing.expectEqual(@as(usize, 3), view.count());
    for ([_]u32{ 1, 2 }) |scale| {
        try view.prepare(scale);
        view.dragScroll(100000, 0);
        try std.testing.expect(view.scroll > 0);
        try std.testing.expect(view.hit(436, 200) == .scrollbar);
        try std.testing.expect(view.scroll <= view.history_height - view.historyRect().height);
        view.focus = action;
        view.ensureFocusVisible();
        const region = view.rect(action);
        try std.testing.expect(region.y >= view.historyRect().y);
        try std.testing.expect(region.y + region.height <= view.historyRect().y + view.historyRect().height);
        try std.testing.expect(std.meta.eql(action, view.hit(region.x + 4, region.y + 4)));
        const count_pixels = view.width * view.height * scale * scale;
        const pixels = try std.testing.allocator.alloc(u32, count_pixels + 2);
        defer std.testing.allocator.free(pixels);
        @memset(pixels, 0x12345678);
        try view.paint(.{ .pixels = pixels[1 .. count_pixels + 1], .width = view.width * scale, .height = view.height * scale });
        try std.testing.expectEqual(@as(u32, 0x12345678), pixels[0]);
        try std.testing.expectEqual(@as(u32, 0x12345678), pixels[count_pixels + 1]);
        // History must never paint over Clear or into the calendar.
        try std.testing.expectEqual(@as(u32, 0xff36363a), pixels[1 + (365 * scale) * view.width * scale + 220 * scale]);
    }
    const dismissal = try view.activate(.{ .notice = .{ .id = 2, .part = .close } });
    try std.testing.expectEqual(@as(u32, 2), dismissal.dismiss);
    try std.testing.expect((try view.activate(.clear)) == .clear);
    try view.load("[]");
    try std.testing.expectEqual(@as(usize, 0), view.count());
    try std.testing.expectEqual(@as(f64, 0), view.scroll);
    try std.testing.expect((try view.activate(.clear)) == .none);
    try std.testing.expect(view.focus == .month);
    try view.load("[{\"id\":-1,\"created\":1},{\"id\":4294967296,\"created\":1},{\"id\":7,\"created\":1},{\"id\":7,\"created\":1}]");
    try std.testing.expectEqual(@as(usize, 1), view.count());
}
