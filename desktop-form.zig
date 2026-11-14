//! Raster form controls hosted directly in native Wayland windows.
const std = @import("std");
pub const c = @import("desktop-gtk.zig");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const input = @import("desktop-password-entry.zig");
pub const host = @import("desktop-window.zig");
const wire = host.wire;
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const cast = c.__zig.cast;
pub const Rect = @import("desktop-askpass-view.zig").Rect;
pub const Kind = enum { heading, label, entry, toggle, button, choice };
pub const Option = struct { id: [:0]const u8, label: [:0]const u8 };
pub const Item = struct {
    owner: *Form,
    id: usize,
    kind: Kind,
    title: [:0]u8,
    hint: [:0]u8,
    entry: ?*input.Entry = null,
    checked: bool = false,
    entry_hash: u64 = std.hash.Wyhash.hash(0, ""),
    enabled: bool = true,
    visible: bool = true,
    clip: ?Rect = null,
    always_enabled: bool = false,
    pinned: bool = false,
    inline_previous: bool = false,
    options: std.ArrayList(Option) = .empty,
    selected: ?usize = null,
    title_mask: ?text.Mask = null,
    hint_mask: ?text.Mask = null,
    choice_mask: ?text.Mask = null,
    option_masks: std.ArrayList(text.Mask) = .empty,
    bounds: Rect = .{ .x = 24, .y = 0, .width = 512, .height = 40 },
    fn invalidate(self: *Item) void {
        for ([_]?text.Mask{ self.title_mask, self.hint_mask, self.choice_mask }) |mask| if (mask) |m| m.deinit(a);
        self.title_mask = null;
        self.hint_mask = null;
        self.choice_mask = null;
        for (self.option_masks.items) |mask| mask.deinit(a);
        self.option_masks.clearRetainingCapacity();
    }
    fn clearOptions(self: *Item) void {
        self.invalidate();
        for (self.options.items) |option| {
            a.free(option.id);
            a.free(option.label);
        }
        self.options.clearRetainingCapacity();
    }
    pub fn value(self: *const Item) [:0]const u8 {
        return if (self.entry) |entry| entry.buffer.valueZ() else "";
    }
    pub fn selectedId(self: *const Item) ?[:0]const u8 {
        return if (self.selected) |index| self.options.items[index].id else null;
    }
};

pub const Form = struct {
    window: *host.Window,
    viewport_height: u32 = 700,
    offset: f64 = 0,
    image: []u32 = &.{},
    footer_image: []u32 = &.{},
    close_callback: ?*const fn (?*anyopaque) void = null,
    actions: std.ArrayList(usize) = .empty,
    dispatching: bool = false,
    action_idle: c.guint = 0,
    last_click: i64 = 0,
    last_item: ?usize = null,
    last_x: f64 = 0,
    last_y: f64 = 0,
    keyboard_focused: bool = true,
    title: [:0]u8,
    items: std.ArrayList(*Item) = .empty,
    context: ?*anyopaque,
    action: *const fn (?*anyopaque, usize) void,
    changed: *const fn (?*anyopaque, usize) void,
    shortcut: ?*const fn (?*anyopaque, u32, u32) bool = null,
    layout: ?*const fn (*Form) void = null,
    painter: ?*const fn (*Form, raster.Buffer, u32) anyerror!void = null,
    scrolled: ?*const fn (?*anyopaque, f64) void = null,
    double_clicked: ?*const fn (?*anyopaque, usize) void = null,
    reveal: ?*const fn (?*anyopaque, usize) void = null,
    focus: ?usize = null,
    hover: ?usize = null,
    pressed: ?usize = null,
    input_modifiers: u32 = 0,
    expanded: ?usize = null,
    option_cursor: usize = 0,
    width: u32 = 560,
    height: u32 = 200,
    footer_height: u32 = 56,
    scale: u32 = 0,
    enabled: bool = true,
    updating: bool = false,
    closed: bool = false,
    renderer: text.Renderer = .{},
    title_mask: ?text.Mask = null,
    pub fn create(title: [:0]const u8, context: ?*anyopaque, action: *const fn (?*anyopaque, usize) void, changed: *const fn (?*anyopaque, usize) void) !*Form {
        const self = try a.create(Form);
        errdefer a.destroy(self);
        const owned_title = try a.dupeSentinel(u8, title, 0);
        errdefer a.free(owned_title);
        const window = try host.Window.create(owned_title, "desktop-form", 620, 700, &draw, self);
        self.* = .{ .window = window, .title = owned_title, .context = context, .action = action, .changed = changed };
        window.context = self;
        window.closed = &destroyed;
        window.surface.?.options.min_width = 480;
        window.surface.?.options.min_height = 200;
        window.surface.?.close = &closeRequested;
        window.surface.?.input = .{ .button = &button, .motion = &motion, .leave = &leave, .scroll = &scrollEvent, .symbol = &key, .text = &commit, .commit = &commit, .preedit = &preedit, .surrounding = &surrounding, .delete = &deleteSurrounding, .focus = &focusChanged };
        return self;
    }
    pub fn deinit(self: *Form) void {
        self.closed = true;
        if (self.action_idle != 0) _ = c.g_source_remove(self.action_idle);
        self.actions.deinit(a);
        for (self.items.items) |item| {
            if (item.entry) |entry| entry.destroy();
            item.clearOptions();
            item.options.deinit(a);
            item.option_masks.deinit(a);
            a.free(item.title);
            a.free(item.hint);
            a.destroy(item);
        }
        self.items.deinit(a);
        if (self.title_mask) |mask| mask.deinit(a);
        self.renderer.deinit();
        self.window.destroy();
        a.free(self.image);
        a.free(self.footer_image);
        a.free(self.title);
        a.destroy(self);
    }
    pub fn add(self: *Form, kind: Kind, title: [:0]const u8, hint: [:0]const u8, secret: bool) !usize {
        try self.items.ensureUnusedCapacity(a, 1);
        const item = try a.create(Item);
        errdefer a.destroy(item);
        const owned_title = try a.dupeSentinel(u8, title, 0);
        errdefer a.free(owned_title);
        const owned_hint = try a.dupeSentinel(u8, hint, 0);
        errdefer a.free(owned_hint);
        item.* = .{ .owner = self, .id = self.items.items.len, .kind = kind, .title = owned_title, .hint = owned_hint };
        if (kind == .entry) {
            item.entry = try input.Entry.create(&entryChanged, item);
            item.entry.?.client = self.window.surface.?.client;
            if (!secret) item.entry.?.makePublic();
        }
        self.items.appendAssumeCapacity(item);
        self.relayout();
        return item.id;
    }
    pub fn addPinned(self: *Form, kind: Kind, title: [:0]const u8) !usize {
        std.debug.assert(kind == .button or kind == .label);
        const id = try self.add(kind, title, "", false);
        self.get(id).pinned = true;
        self.relayout();
        return id;
    }
    pub fn pair(self: *Form, first: usize, second: usize) void {
        std.debug.assert(second == first + 1 and self.get(first).kind == .button and self.get(second).kind == .button);
        self.get(second).inline_previous = true;
        self.relayout();
    }
    pub fn get(self: *Form, id: usize) *Item {
        return self.items.items[id];
    }
    /// Remove a dynamic suffix without replacing the window or fixed controls.
    pub fn truncate(self: *Form, count: usize) void {
        std.debug.assert(count <= self.items.items.len);
        // IDs in the dynamic suffix may be reused by the next listing.
        self.actions.clearRetainingCapacity();
        if (self.action_idle != 0) _ = c.g_source_remove(self.action_idle);
        self.action_idle = 0;
        if (self.focus) |id| if (id >= count) {
            self.focus = null;
        };
        if (self.hover) |id| if (id >= count) {
            self.hover = null;
        };
        if (self.pressed) |id| if (id >= count) {
            self.pressed = null;
        };
        if (self.expanded) |id| if (id >= count) {
            self.expanded = null;
        };
        for (self.items.items[count..]) |item| {
            if (item.entry) |entry| entry.destroy();
            item.clearOptions();
            item.options.deinit(a);
            item.option_masks.deinit(a);
            a.free(item.title);
            a.free(item.hint);
            a.destroy(item);
        }
        self.items.shrinkRetainingCapacity(count);
        self.relayout();
    }
    pub fn setText(self: *Form, id: usize, value: [:0]const u8) !void {
        const field = self.get(id);
        if (field.entry) |entry| {
            if (std.mem.eql(u8, entry.buffer.value(), value)) return;
            // Validate before clearing so a rejected edit preserves the old value.
            if (value.len > input.Buffer.capacity or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidText;
            self.updating = true;
            defer self.updating = false;
            entry.clear();
            try entry.insert(value);
        } else {
            const copy = try a.dupeSentinel(u8, value, 0);
            a.free(field.title);
            field.title = copy;
            field.invalidate();
        }
        self.redraw();
    }
    pub fn setChecked(self: *Form, id: usize, checked: bool) void {
        self.get(id).checked = checked;
        self.redraw();
    }
    pub fn setEnabled(self: *Form, enabled: bool) void {
        self.enabled = enabled;
        if (!enabled) self.expanded = null;
        self.updateFocus();
        self.relayout();
    }
    pub fn setOptions(self: *Form, id: usize, options: []const Option, default_first: bool) !void {
        const field = self.get(id);
        var next: std.ArrayList(Option) = .empty;
        errdefer {
            for (next.items) |option| {
                a.free(option.id);
                a.free(option.label);
            }
            next.deinit(a);
        }
        try next.ensureTotalCapacity(a, options.len);
        var selected: ?usize = null;
        const previous = field.selectedId();
        for (options, 0..) |option, index| {
            const key_copy = try a.dupeSentinel(u8, option.id, 0);
            errdefer a.free(key_copy);
            const label_copy = try a.dupeSentinel(u8, option.label, 0);
            next.appendAssumeCapacity(.{ .id = key_copy, .label = label_copy });
            if (previous) |key_value| if (std.mem.eql(u8, key_value, option.id)) {
                selected = index;
            };
        }
        field.clearOptions();
        field.options.deinit(a);
        field.options = next;
        field.selected = selected orelse if (default_first and options.len != 0) @as(?usize, 0) else null;
        if (self.expanded == id) self.option_cursor = @min(self.option_cursor, options.len -| 1);
        self.relayout();
    }
    pub fn select(self: *Form, id: usize, selected_id: ?[]const u8) bool {
        const field = self.get(id);
        field.selected = null;
        if (selected_id) |wanted| for (field.options.items, 0..) |option, index| {
            if (std.mem.eql(u8, wanted, option.id)) {
                field.selected = index;
                break;
            }
        };
        if (field.choice_mask) |mask| mask.deinit(a);
        field.choice_mask = null;
        self.redraw();
        return field.selected != null;
    }
    fn entryChanged(ptr: ?*anyopaque) void {
        const field = cast(Item, ptr);
        const self = field.owner;
        if (self.closed) return;
        self.redraw();
        const hash = std.hash.Wyhash.hash(0, field.entry.?.buffer.value());
        const edited = hash != field.entry_hash;
        field.entry_hash = hash;
        if (!self.updating and edited) self.changed(self.context, field.id);
    }
    pub fn active(self: *const Form, id: usize) bool {
        const field = self.items.items[id];
        return field.visible and (self.enabled or field.always_enabled) and field.enabled and field.kind != .heading and field.kind != .label and (field.kind != .choice or field.options.items.len != 0);
    }
    pub fn relayout(self: *Form) void {
        if (self.updating) return;
        if (self.layout) |layout| {
            layout(self);
            self.updateFocus();
            self.redraw();
            return;
        }
        var y: f64 = 76;
        var pinned_buttons: usize = 0;
        for (self.items.items) |field| {
            if (field.pinned) {
                field.bounds = if (field.kind == .label) .{ .x = 24, .y = 8, .width = @floatFromInt(self.width - 48), .height = 40 } else .{ .x = 24 + @as(f64, @floatFromInt(pinned_buttons)) * @as(f64, @floatFromInt(self.width - 36)) / 2, .y = 56, .width = @as(f64, @floatFromInt(self.width - 60)) / 2, .height = 40 };
                if (field.kind == .button) pinned_buttons += 1;
                continue;
            }
            if (field.inline_previous) {
                const previous = self.get(field.id - 1).bounds;
                field.bounds = .{ .x = @as(f64, @floatFromInt(self.width)) / 2 + 6, .y = previous.y, .width = previous.width, .height = previous.height };
                continue;
            }
            const paired = field.id + 1 < self.items.items.len and self.get(field.id + 1).inline_previous;
            const height: f64 = switch (field.kind) {
                .heading => 40,
                .label => 52,
                .entry => 100,
                .choice => 84,
                else => 48,
            };
            field.bounds = .{ .x = 24, .y = y, .width = if (paired) @as(f64, @floatFromInt(self.width - 60)) / 2 else @as(f64, @floatFromInt(self.width - 48)), .height = height - 8 };
            if (field.entry) |entry| entry.rect = .{ .x = 24, .y = y + 26, .width = @floatFromInt(self.width - 48), .height = 40 };
            y += height;
            if (self.expanded == field.id) y += @as(f64, @floatFromInt(field.options.items.len * 36));
        }
        self.height = @intFromFloat(y + 24);
        self.footer_height = if (pinned_buttons == 0) 56 else 112;
        self.redraw();
    }
    pub fn redraw(self: *Form) void {
        if (!self.closed) self.window.redraw();
        self.syncInput();
    }
    pub fn show(self: *Form) void {
        self.relayout();
        self.window.show() catch self.window.close();
    }
    pub fn close(self: *Form) void {
        self.window.close();
    }
    fn bodyHeight(self: *const Form) u32 {
        var pinned = false;
        for (self.items.items) |item| if (item.pinned and item.visible) {
            pinned = true;
            break;
        };
        return self.viewport_height -| (if (pinned) @min(self.footer_height, self.viewport_height) else @as(u32, 0));
    }
    fn clampOffset(self: *Form) void {
        self.offset = if (self.layout != null) 0 else std.math.clamp(self.offset, 0, @as(f64, @floatFromInt(self.height -| self.bodyHeight())));
    }
    fn revealBounds(self: *Form, top: f64, bottom: f64) void {
        if (self.layout != null) return;
        if (top < self.offset) self.offset = top;
        if (bottom > self.offset + @as(f64, @floatFromInt(self.bodyHeight()))) self.offset = bottom - @as(f64, @floatFromInt(self.bodyHeight()));
        self.clampOffset();
    }
    pub fn focusItem(self: *Form, id: usize) void {
        self.focus = id;
        self.updateFocus();
        const bounds = self.get(id).bounds;
        if (!self.get(id).pinned) self.revealBounds(bounds.y, bounds.y + bounds.height);
        if (self.reveal) |reveal| reveal(self.context, id);
        self.redraw();
    }
    fn updateFocus(self: *Form) void {
        for (self.items.items) |field| if (field.entry) |entry| entry.focus(!self.closed and self.keyboard_focused and self.active(field.id) and self.focus == field.id);
    }
    fn optionHit(self: *const Form, x: f64, y: f64) ?usize {
        const id = self.expanded orelse return null;
        const field = self.items.items[id];
        const top = self.optionTop(field);
        const left = if (self.layout != null) field.bounds.x else 24;
        const right = if (self.layout != null) field.bounds.x + field.bounds.width else @as(f64, @floatFromInt(self.width - 24));
        if (x < left or x >= right or y < top) return null;
        const index: usize = @intFromFloat((y - top) / 36);
        return if (index < field.options.items.len) index else null;
    }
    pub fn hit(self: *const Form, x: f64, y: f64) ?usize {
        return self.hitSurface(x, y, false);
    }
    fn hitSurface(self: *const Form, x: f64, y: f64, footer: bool) ?usize {
        for (self.items.items) |field| if (field.pinned == footer and self.active(field.id) and field.bounds.contains(x, y)) {
            if (field.clip) |clip| if (!clip.contains(x, y)) continue;
            return field.id;
        };
        return null;
    }
    pub fn optionTop(self: *const Form, field: *const Item) f64 {
        const space: f64 = @floatFromInt(field.options.items.len * 36);
        if (self.layout != null and field.bounds.y + field.bounds.height + 8 + space > @as(f64, @floatFromInt(self.height))) return @max(46, field.bounds.y - space - 8);
        return field.bounds.y + field.bounds.height + 8;
    }
    pub fn activate(self: *Form, id: usize) void {
        if (self.closed or self.window.closing or !self.active(id)) return;
        const field = self.get(id);
        switch (field.kind) {
            .button => {
                if (self.dispatching) {
                    self.actions.append(a, id) catch {
                        self.close();
                        return;
                    };
                    if (self.action_idle == 0) self.action_idle = c.g_idle_add(&deliverAction, self);
                } else self.action(self.context, id);
            },
            .toggle => {
                field.checked = !field.checked;
                self.changed(self.context, id);
                self.redraw();
            },
            .choice => {
                self.expanded = if (self.expanded == id) null else id;
                self.option_cursor = field.selected orelse 0;
                self.relayout();
            },
            else => {},
        }
    }
    fn orderedId(self: *const Form, ordinal: usize) usize {
        var index: usize = 0;
        // Dynamically appended fields stay before the fixed footer in tab order.
        for ([_]bool{ false, true }) |pinned| for (self.items.items) |field| {
            if (field.pinned != pinned) continue;
            if (index == ordinal) return field.id;
            index += 1;
        };
        unreachable;
    }
    pub fn handleKey(self: *Form, symbol: u32, modifiers: c.GdkModifierType) bool {
        self.input_modifiers = modifiers;
        if (self.closed or self.window.closing) return false;
        if (symbol == 0xff1b) {
            if (self.expanded != null) {
                self.expanded = null;
                self.relayout();
            } else self.close();
            return true;
        }
        if (symbol == 0xff09 or symbol == 0xfe20) {
            self.expanded = null;
            self.relayout();
            const n = self.items.items.len;
            if (n == 0) return true;
            const backwards = symbol == 0xfe20 or modifiers & c.GDK_SHIFT_MASK != 0;
            var start = if (backwards) @as(usize, 0) else n - 1;
            if (self.focus) |focused| for (0..n) |index| {
                if (self.orderedId(index) == focused) {
                    start = index;
                    break;
                }
            };
            for (1..n + 1) |step| {
                const index = if (backwards) (start + n - step) % n else (start + step) % n;
                const id = self.orderedId(index);
                if (self.active(id)) {
                    self.focusItem(id);
                    break;
                }
            }
            return true;
        }
        const id = self.focus orelse return false;
        if (!self.active(id)) return false;
        const field = self.get(id);
        if (field.kind == .choice and (symbol == 0xff52 or symbol == 0xff54 or symbol == 0xff0d or symbol == 0x20)) {
            if (self.expanded == id and (symbol == 0xff0d or symbol == 0x20)) {
                const key_value = field.options.items[self.option_cursor].id;
                _ = self.select(id, key_value);
                self.expanded = null;
                self.relayout();
                self.changed(self.context, id);
            } else if (self.expanded == id) {
                const n = field.options.items.len;
                self.option_cursor = if (symbol == 0xff52) (self.option_cursor + n - 1) % n else (self.option_cursor + 1) % n;
                const top = self.optionTop(field) + @as(f64, @floatFromInt(self.option_cursor * 36));
                self.revealBounds(top, top + 36);
                self.redraw();
            } else self.activate(id);
            return true;
        }
        if (field.entry) |entry| {
            if (entry.key(symbol, modifiers)) return true;
            const codepoint = @import("desktop-keyboard.zig").unicode(symbol);
            if (modifiers & (c.GDK_CONTROL_MASK | c.GDK_MOD1_MASK) != 0 or codepoint < 32 or codepoint == 127) return false;
            var bytes: [4]u8 = @splat(0);
            defer std.crypto.secureZero(u8, &bytes);
            const len = std.unicode.utf8Encode(@intCast(codepoint), &bytes) catch return false;
            entry.insert(bytes[0..len]) catch return true;
            return true;
        }
        if (symbol == 0xff0d or symbol == 0x20) {
            self.activate(id);
            return true;
        }
        return false;
    }
    fn destroyed(ptr: ?*anyopaque) void {
        const self = cast(Form, ptr);
        self.closed = true;
        self.updateFocus();
        if (self.close_callback) |callback| callback(self.context);
    }
    fn closeRequested(ptr: ?*anyopaque) void {
        cast(Form, ptr).close();
    }
    fn focusedEntry(self: *Form) ?*input.Entry {
        const id = self.focus orelse return null;
        return if (!self.closed and !self.window.closing and self.active(id)) self.get(id).entry else null;
    }
    fn syncInput(self: *Form) void {
        const surface = self.window.surface orelse return;
        for (surface.client.seats.items) |seat| if (seat.text_input) |im| if (im.surface == surface) im.update();
    }
    fn key(ptr: ?*anyopaque, _: *wire.Surface, symbol: u32, modifiers: u32, pressed: bool) bool {
        const self = cast(Form, ptr);
        self.input_modifiers = modifiers;
        if (!pressed or self.closed or self.window.blocked()) return true;
        self.dispatching = true;
        defer self.dispatching = false;
        if (self.shortcut) |callback| if (callback(self.context, symbol, modifiers)) return true;
        if (self.focusedEntry()) |entry| {
            if (symbol != 0xff09 and symbol != 0xfe20 and symbol != 0xff1b) return entry.key(symbol, modifiers);
        }
        return self.handleKey(symbol, modifiers);
    }
    fn deliverAction(ptr: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Form, ptr);
        self.action_idle = 0;
        const id = self.actions.orderedRemove(0);
        if (self.actions.items.len != 0) self.action_idle = c.g_idle_add(&deliverAction, self);
        if (!self.closed and id < self.items.items.len) self.activate(id);
        return 0;
    }
    fn commit(ptr: ?*anyopaque, _: *wire.Surface, value: []const u8) void {
        const self = cast(Form, ptr);
        if (!self.window.blocked()) if (self.focusedEntry()) |entry| entry.insert(value) catch {};
    }
    fn preedit(ptr: ?*anyopaque, _: *wire.Surface, value: []const u8, _: i32) void {
        const self = cast(Form, ptr);
        if (self.focusedEntry()) |entry| entry.setPreedit(value);
    }
    fn surrounding(ptr: ?*anyopaque, _: *wire.Surface) ?@import("desktop-input.zig").TextState {
        const self = cast(Form, ptr);
        if (self.window.blocked()) return null;
        const entry = self.focusedEntry() orelse return null;
        const rect = entry.location;
        return .{ .text = if (entry.public_text) entry.buffer.valueZ() else "", .cursor = if (entry.public_text) @intCast(entry.buffer.cursor) else 0, .anchor = if (entry.public_text) @intCast(entry.buffer.anchor) else 0, .rect = .{ .x = rect.x, .y = rect.y - @as(i32, @intFromFloat(self.offset)), .width = rect.width, .height = rect.height }, .private = !entry.public_text };
    }
    fn deleteSurrounding(ptr: ?*anyopaque, _: *wire.Surface, before: u32, after: u32) void {
        const self = cast(Form, ptr);
        if (self.focusedEntry()) |entry| entry.deleteSurrounding(before, after);
    }
    fn focusChanged(ptr: ?*anyopaque, _: *wire.Surface, focused: bool) void {
        const self = cast(Form, ptr);
        self.keyboard_focused = focused;
        self.pressed = null;
        self.updateFocus();
    }
    fn coordinates(self: *Form, y: f64) struct { y: f64, footer: bool } {
        const body: f64 = @floatFromInt(self.bodyHeight());
        return if (y >= body) .{ .y = y - body, .footer = true } else .{ .y = y + self.offset, .footer = false };
    }
    pub fn pointerButton(self: *Form, pressed: bool, x: f64, screen_y: f64) void {
        if (self.closed or self.window.closing or self.window.blocked()) return;
        const pos = self.coordinates(screen_y);
        const y = pos.y;
        if (pressed) {
            if (!pos.footer) if (self.optionHit(x, y)) |index| {
                self.option_cursor = index;
                self.pressed = self.expanded;
                return;
            };
            const id = self.hitSurface(x, y, pos.footer) orelse {
                self.expanded = null;
                self.relayout();
                return;
            };
            const now = c.g_get_monotonic_time();
            const double = self.last_item == id and now - self.last_click < 400_000 and @abs(x - self.last_x) < 5 and @abs(screen_y - self.last_y) < 5;
            self.last_item = id;
            self.last_click = now;
            self.last_x = x;
            self.last_y = screen_y;
            if (double) if (self.double_clicked) |callback| {
                self.last_item = null;
                self.pressed = null;
                callback(self.context, id);
                return;
            };
            if (self.expanded != null and self.expanded != id) {
                self.expanded = null;
                self.relayout();
            }
            self.pressed = id;
            self.focusItem(id);
            if (self.get(id).entry) |entry| {
                entry.dragging = true;
                entry.point(x, self.input_modifiers & 1 != 0);
            }
        } else {
            const id = self.pressed orelse return;
            self.pressed = null;
            if (self.get(id).entry) |entry| {
                entry.dragging = false;
                return;
            }
            if (self.expanded == id) if (self.optionHit(x, y)) |index| {
                if (index == self.option_cursor) {
                    _ = self.select(id, self.get(id).options.items[index].id);
                    self.expanded = null;
                    self.relayout();
                    self.changed(self.context, id);
                }
                return;
            };
            if (self.hitSurface(x, y, pos.footer) == id) self.activate(id);
        }
    }
    // A button action may destroy its form or enter a nested dialog loop.
    fn button(ptr: ?*anyopaque, surface: *wire.Surface, code: u32, pressed: bool, x: f64, y: f64) void {
        if (code != 0x110) return;
        const self = cast(Form, ptr);
        self.dispatching = true;
        defer self.dispatching = false;
        for (surface.client.seats.items) |seat| if (seat.pointer_focus == surface) {
            self.input_modifiers = seat.xkb.modifiers();
            break;
        };
        self.pointerButton(pressed, x, y);
    }
    fn motion(ptr: ?*anyopaque, _: *wire.Surface, x: f64, y: f64) void {
        const self = cast(Form, ptr);
        const pos = self.coordinates(y);
        self.hover = self.hitSurface(x, pos.y, pos.footer);
        if (self.focusedEntry()) |entry| if (entry.dragging) entry.point(x, true);
        self.redraw();
    }
    fn leave(ptr: ?*anyopaque, _: *wire.Surface) void {
        const self = cast(Form, ptr);
        self.hover = null;
        if (self.focusedEntry()) |entry| entry.dragging = false;
        self.redraw();
    }
    fn scrollEvent(ptr: ?*anyopaque, _: *wire.Surface, axis: u32, delta: f64) void {
        const self = cast(Form, ptr);
        if (axis != 0) return;
        if (self.scrolled) |callback| callback(self.context, delta * 3) else {
            self.offset += delta * 3;
            self.clampOffset();
            self.redraw();
        }
    }
    fn draw(ptr: ?*anyopaque, target: wire.Pixels) void {
        const self = cast(Form, ptr);
        self.paintWindow(target) catch self.close();
    }
    fn resizeImage(storage: *[]u32, width: u32, height: u32) !raster.Buffer {
        const bytes = try wire.bufferSize(width, height);
        if (storage.len != bytes / 4) {
            const pixels = try a.alloc(u32, bytes / 4);
            a.free(storage.*);
            storage.* = pixels;
        }
        return .{ .pixels = storage.*, .width = width, .height = height };
    }
    fn paintWindow(self: *Form, target: wire.Pixels) !void {
        const surface = self.window.surface orelse return;
        const scale = surface.output.scale;
        self.viewport_height = target.height / scale;
        if (self.layout != null) self.height = self.viewport_height;
        self.prepareLayout(target.width / scale, scale);
        if (self.layout != null) {
            self.relayout();
            try self.paintPixels(target, scale, false);
            return;
        }
        self.clampOffset();
        const body = self.bodyHeight() * scale;
        const image = try resizeImage(&self.image, target.width, @max(self.height * scale, body));
        try self.paintPixels(image, scale, false);
        const start: usize = @intFromFloat(self.offset * @as(f64, @floatFromInt(scale)));
        for (0..body) |row| @memcpy(target.pixels[row * target.width ..][0..target.width], image.pixels[(start + row) * target.width ..][0..target.width]);
        if (body < target.height) {
            const footer = try resizeImage(&self.footer_image, target.width, self.footer_height * scale);
            try self.paintPixels(footer, scale, true);
            @memcpy(target.pixels[@as(usize, body) * target.width ..], footer.pixels[0 .. @as(usize, target.height - body) * target.width]);
        }
    }
    fn makeMask(self: *Form, value: [:0]const u8, width: u32, bold: bool) !text.Mask {
        const scale: f64 = @floatFromInt(self.scale);
        return self.renderer.renderLayout(a, value, .{ .font = if (bold) "Adwaita Sans Bold" else "Adwaita Sans", .size = (if (bold) @as(f64, 15) else 14) * scale, .dpi = 96 * scale, .width = width * self.scale, .lines = 2, .ellipsize = true, .origin = .top });
    }
    fn prepareLayout(self: *Form, width: u32, scale: u32) void {
        if (self.scale != scale or self.width != width) {
            if (self.title_mask) |old| old.deinit(a);
            self.title_mask = null;
            for (self.items.items) |field| field.invalidate();
            self.scale = scale;
            self.width = width;
            self.relayout();
        }
    }
    pub fn paintPixels(self: *Form, target: raster.Buffer, scale: u32, footer: bool) !void {
        const width = target.width / scale;
        self.prepareLayout(width, scale);
        if (self.painter) |painter| {
            try painter(self, target, scale);
            return;
        }
        @memset(target.pixels, 0xff242428);
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        if (self.title_mask == null) self.title_mask = try self.renderer.renderLayout(a, self.title, .{ .font = "Adwaita Sans Bold", .size = 22 * @as(f64, @floatFromInt(scale)), .dpi = 96 * @as(f64, @floatFromInt(scale)), .width = (width - 48) * scale, .ellipsize = true, .origin = .top });
        if (!footer) drawText(canvas, self.title_mask.?, 24, 24, 0xffffff);
        for (self.items.items) |field| {
            if (field.pinned != footer) continue;
            const bounds = field.bounds;
            const active_tint: u32 = if ((self.enabled and field.enabled) or field.kind == .label or field.kind == .heading) 0xffffff else 0x99999f;
            if (field.title_mask == null) field.title_mask = try self.makeMask(field.title, width - 100, field.kind == .heading);
            switch (field.kind) {
                .heading, .label => drawText(canvas, field.title_mask.?, bounds.x, bounds.y + 6, active_tint),
                .entry => {
                    drawText(canvas, field.title_mask.?, bounds.x, bounds.y + 2, active_tint);
                    try field.entry.?.paint(target, scale);
                    if (field.hint.len != 0) {
                        if (field.hint_mask == null) field.hint_mask = try self.makeMask(field.hint, width - 48, false);
                        drawText(canvas, field.hint_mask.?, bounds.x, bounds.y + 72, 0xababaf);
                    }
                },
                .button, .toggle, .choice => {
                    var box = bounds;
                    if (field.kind == .choice) {
                        drawText(canvas, field.title_mask.?, bounds.x, bounds.y, active_tint);
                        box.y += 26;
                        box.height -= 26;
                    }
                    canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height }, .radius = 9 } }}, color(if (field.kind == .toggle and field.checked) @as(u32, 0x245b98) else if (self.hover == field.id) @as(u32, 0x505055) else 0x36363c));
                    if (field.kind == .choice) {
                        const label = if (field.selected) |index| field.options.items[index].label else "Select…";
                        if (field.choice_mask == null) field.choice_mask = try self.makeMask(label, width - 100, false);
                        drawText(canvas, field.choice_mask.?, box.x + 12, box.y + 10, active_tint);
                        canvas.draw(&.{ .{ .line = .{ .start = .{ .x = box.x + box.width - 22, .y = box.y + 18 }, .end = .{ .x = box.x + box.width - 16, .y = box.y + 24 } } }, .{ .line = .{ .start = .{ .x = box.x + box.width - 16, .y = box.y + 24 }, .end = .{ .x = box.x + box.width - 10, .y = box.y + 18 } } } }, color(active_tint));
                    } else {
                        drawText(canvas, field.title_mask.?, box.x + 12, box.y + 10, active_tint);
                        if (field.kind == .toggle and field.checked) canvas.draw(&.{.{ .circle = .{ .center = .{ .x = box.x + box.width - 20, .y = box.y + 20 }, .radius = 5 } }}, color(0xffffff));
                    }
                    if (self.focus == field.id and self.active(field.id)) canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = box.x + 1, .y = box.y + 1, .width = box.width - 2, .height = box.height - 2 }, .radius = 8, .width = 2 } }}, color(0x99c1f1));
                },
            }
            if (self.expanded == field.id) {
                for (field.options.items, 0..) |option, index| {
                    if (field.option_masks.items.len <= index) {
                        const label_mask = try self.makeMask(option.label, width - 80, false);
                        field.option_masks.append(a, label_mask) catch |err| {
                            label_mask.deinit(a);
                            return err;
                        };
                    }
                    const top = bounds.y + bounds.height + 8 + @as(f64, @floatFromInt(index * 36));
                    canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = 24, .y = top, .width = bounds.width, .height = 36 }, .radius = 4 } }}, color(if (self.option_cursor == index) 0x245b98 else 0x36363c));
                    drawText(canvas, field.option_masks.items[index], 36, top + 8, 0xffffff);
                }
            }
        }
    }
};
const color = raster.hex;
fn drawText(canvas: raster.Canvas, mask_value: text.Mask, x: f64, y: f64, tint: u32) void {
    mask_value.paint(canvas, x, y, color(tint));
}

test "native forms preserve selections, isolate passwords and navigate controls" {
    const Callbacks = struct {
        edits: usize = 0,
        actions: usize = 0,
        fn changed(ptr: ?*anyopaque, _: usize) void {
            cast(@This(), ptr).edits += 1;
        }
        fn action(ptr: ?*anyopaque, _: usize) void {
            cast(@This(), ptr).actions += 1;
        }
    };
    var callbacks: Callbacks = .{};
    const form = try Form.create("Native form", &callbacks, &Callbacks.action, &Callbacks.changed);
    defer form.deinit();
    const name = try form.add(.entry, "Network name", "", false);
    const secret = try form.add(.entry, "Password", "", true);
    const choice = try form.add(.choice, "Saved connections", "", false);
    const toggle = try form.add(.toggle, "Hidden network", "", false);
    const button = try form.add(.button, "Connect", "", false);
    try form.setText(name, "Cafe 東京");
    try form.setText(secret, "private-secret");
    try form.setOptions(choice, &.{ .{ .id = "/one", .label = "First" }, .{ .id = "/two", .label = "Second" } }, true);
    try std.testing.expect(form.select(choice, "/two"));
    try form.setOptions(choice, &.{ .{ .id = "/two", .label = "Renamed" }, .{ .id = "/one", .label = "First" } }, true);
    try std.testing.expectEqualStrings("/two", form.get(choice).selectedId().?);
    try std.testing.expectEqualStrings("Cafe 東京", form.get(name).value());
    form.show();
    form.focusItem(name);
    try std.testing.expectEqual(@as(usize, 0), callbacks.edits);
    try std.testing.expect(form.handleKey('a', c.GDK_CONTROL_MASK));
    try std.testing.expect(form.handleKey('c', c.GDK_CONTROL_MASK));
    form.focusItem(secret);
    try std.testing.expect(form.handleKey('a', c.GDK_CONTROL_MASK));
    try std.testing.expect(form.handleKey('c', c.GDK_CONTROL_MASK));
    // A password copy must leave the public clipboard selection untouched.
    try form.setText(name, "");
    form.focusItem(name);
    try std.testing.expect(form.handleKey('v', c.GDK_CONTROL_MASK));
    const deadline = c.g_get_monotonic_time() + 2_000_000;
    while (form.get(name).value().len == 0 and c.g_get_monotonic_time() < deadline) {
        _ = c.g_main_context_iteration(null, 0);
        c.g_usleep(1000);
    }
    try std.testing.expectEqualStrings("Cafe 東京", form.get(name).value());
    try std.testing.expect(!form.get(secret).entry.?.public_text);
    try std.testing.expect(!form.get(secret).entry.?.echo);
    form.focusItem(choice);
    try std.testing.expect(form.handleKey(0xff0d, 0));
    try std.testing.expect(form.expanded == choice);
    try std.testing.expect(form.handleKey(0xff54, 0));
    try std.testing.expect(form.handleKey(0xff0d, 0));
    try std.testing.expectEqualStrings("/one", form.get(choice).selectedId().?);
    try std.testing.expect(form.expanded == null);
    try std.testing.expect(form.handleKey(0xff09, 0));
    try std.testing.expectEqual(toggle, form.focus.?);
    try std.testing.expect(form.handleKey(0x20, 0));
    try std.testing.expect(form.get(toggle).checked);
    form.pointerButton(true, form.get(toggle).bounds.x + 10, form.get(toggle).bounds.y + 10 - form.offset);
    form.pointerButton(false, form.get(toggle).bounds.x + 10, form.get(toggle).bounds.y + 10 - form.offset);
    try std.testing.expect(!form.get(toggle).checked);
    form.get(toggle).enabled = false;
    form.focusItem(button);
    try std.testing.expect(form.handleKey(0xfe20, c.GDK_SHIFT_MASK));
    try std.testing.expectEqual(choice, form.focus.?);
    form.activate(button);
    try std.testing.expectEqual(@as(usize, 1), callbacks.actions);
    const pinned = try form.addPinned(.button, "Cancel");
    form.get(pinned).always_enabled = true;
    _ = try form.addPinned(.label, "Validation message");
    for ([_]u32{ 1, 2 }) |scale| {
        const pixels = try std.testing.allocator.alloc(u32, 620 * 720 * scale * scale);
        defer std.testing.allocator.free(pixels);
        try form.paintPixels(.{ .pixels = pixels, .width = 620 * scale, .height = 720 * scale }, scale, false);
        try form.paintPixels(.{ .pixels = pixels, .width = 620 * scale, .height = 720 * scale }, scale, true);
        try std.testing.expect(form.get(pinned).bounds.y < 112);
    }
    form.setEnabled(false);
    form.activate(button);
    try std.testing.expectEqual(@as(usize, 1), callbacks.actions);
    const footer_y = @as(f64, @floatFromInt(form.bodyHeight())) + form.get(pinned).bounds.y + 10;
    form.pointerButton(true, form.get(pinned).bounds.x + 10, footer_y);
    form.pointerButton(false, form.get(pinned).bounds.x + 10, footer_y);
    try std.testing.expectEqual(@as(usize, 2), callbacks.actions);
    const late_field = try form.add(.entry, "Additional property", "", false);
    form.setEnabled(true);
    form.focusItem(late_field);
    try std.testing.expect(form.handleKey(0xff09, 0));
    try std.testing.expectEqual(pinned, form.focus.?);
    form.close();
    const previous_actions = callbacks.actions;
    form.activate(button);
    try std.testing.expectEqual(previous_actions, callbacks.actions);
    while (!form.closed) _ = c.g_main_context_iteration(null, 1);
    try std.testing.expect(form.closed);
}

test "native form children share their parent connection and close before parent teardown" {
    const Owner = struct {
        closes: usize = 0,
        fn action(_: ?*anyopaque, _: usize) void {}
        fn changed(_: ?*anyopaque, _: usize) void {}
        fn closed(ptr: ?*anyopaque) void {
            cast(@This(), ptr).closes += 1;
        }
    };
    var owner: Owner = .{};
    const parent = try Form.create("Parent form", &owner, &Owner.action, &Owner.changed);
    defer parent.deinit();
    const child = try Form.create("Child form", &owner, &Owner.action, &Owner.changed);
    defer child.deinit();
    parent.close_callback = &Owner.closed;
    child.close_callback = &Owner.closed;
    child.window.parent = parent.window;
    parent.show();
    child.show();
    try std.testing.expectEqual(parent.window.surface.?.client, child.window.surface.?.client);
    try std.testing.expect(parent.window.blocked());
    parent.close();
    const deadline = c.g_get_monotonic_time() + 2_000_000;
    while (owner.closes != 2 and c.g_get_monotonic_time() < deadline) {
        _ = c.g_main_context_iteration(null, 0);
        c.g_usleep(1000);
    }
    try std.testing.expectEqual(@as(usize, 2), owner.closes);
    try std.testing.expect(parent.closed and child.closed);
}
