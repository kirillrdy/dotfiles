//! Raster form controls with GTK hosting and the shared native input method entry.
const std = @import("std");
pub const c = @import("desktop-gtk.zig");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const input = @import("desktop-password-entry.zig");
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
    window: *c.GtkWidget,
    canvas: *c.GtkWidget,
    scroll: *c.GtkWidget,
    footer: *c.GtkWidget,
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
        const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL).?;
        errdefer c.gtk_widget_destroy(window);
        c.gtk_window_set_title(cast(c.GtkWindow, window), title);
        c.gtk_window_set_default_size(cast(c.GtkWindow, window), 620, 700);
        const scroll = c.gtk_scrolled_window_new(null, null).?;
        c.gtk_scrolled_window_set_policy(cast(c.GtkScrolledWindow, scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        const canvas = c.gtk_drawing_area_new().?;
        c.gtk_widget_set_can_focus(canvas, 1);
        c.gtk_widget_add_events(canvas, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK | c.GDK_POINTER_MOTION_MASK | c.GDK_KEY_PRESS_MASK | c.GDK_KEY_RELEASE_MASK | c.GDK_FOCUS_CHANGE_MASK);
        c.gtk_container_add(cast(c.GtkContainer, scroll), canvas);
        const footer = c.gtk_drawing_area_new().?;
        c.gtk_widget_add_events(footer, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK | c.GDK_POINTER_MOTION_MASK);
        c.gtk_widget_set_no_show_all(footer, 1);
        const host = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        c.gtk_box_pack_start(cast(c.GtkBox, host), scroll, 1, 1, 0);
        c.gtk_box_pack_start(cast(c.GtkBox, host), footer, 0, 0, 0);
        c.gtk_container_add(cast(c.GtkContainer, window), host);
        _ = c.g_object_ref(window);
        _ = c.g_object_ref(canvas);
        _ = c.g_object_ref(footer);
        self.* = .{ .window = window, .canvas = canvas, .scroll = scroll, .footer = footer, .title = owned_title, .context = context, .action = action, .changed = changed };
        self.connect(canvas, "draw", &draw);
        self.connect(canvas, "button-press-event", &press);
        self.connect(canvas, "button-release-event", &release);
        self.connect(canvas, "motion-notify-event", &motion);
        self.connect(canvas, "scroll-event", &scrollEvent);
        self.connect(canvas, "key-press-event", &key);
        self.connect(canvas, "key-release-event", &keyRelease);
        self.connect(canvas, "focus-in-event", &focusIn);
        self.connect(canvas, "focus-out-event", &focusOut);
        self.connect(footer, "draw", &draw);
        self.connect(footer, "button-press-event", &press);
        self.connect(footer, "button-release-event", &release);
        self.connect(footer, "motion-notify-event", &motion);
        self.connect(window, "destroy", &destroyed);
        return self;
    }
    fn connect(self: *Form, widget: anytype, signal: [*:0]const u8, callback: anytype) void {
        _ = c.g_signal_connect_data(widget, signal, @ptrCast(callback), self, null, 0);
    }
    pub fn deinit(self: *Form) void {
        _ = c.g_signal_handlers_disconnect_matched(self.footer, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        _ = c.g_signal_handlers_disconnect_matched(self.canvas, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        _ = c.g_signal_handlers_disconnect_matched(self.window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
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
        c.gtk_widget_destroy(self.window);
        c.g_object_unref(self.canvas);
        c.g_object_unref(self.footer);
        c.g_object_unref(self.window);
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
            item.entry = try input.Entry.create(self.canvas, &entryChanged, item);
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
        c.gtk_widget_set_no_show_all(self.footer, 0);
        c.gtk_widget_show(self.footer);
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
        if (!self.closed) c.gtk_widget_set_size_request(self.footer, 480, @intCast(self.footer_height));
        if (!self.closed) c.gtk_widget_set_size_request(self.canvas, 480, @intCast(self.height));
        self.redraw();
    }
    pub fn redraw(self: *Form) void {
        if (!self.closed) {
            c.gtk_widget_queue_draw(self.canvas);
            c.gtk_widget_queue_draw(self.footer);
        }
    }
    pub fn show(self: *Form) void {
        self.relayout();
        c.gtk_widget_show_all(self.window);
        c.gtk_widget_grab_focus(self.canvas);
    }
    pub fn focusItem(self: *Form, id: usize) void {
        self.focus = id;
        self.updateFocus();
        const bounds = self.get(id).bounds;
        if (self.layout == null and !self.get(id).pinned) c.gtk_adjustment_clamp_page(c.gtk_scrolled_window_get_vadjustment(cast(c.GtkScrolledWindow, self.scroll)), bounds.y, bounds.y + bounds.height);
        self.redraw();
    }
    fn updateFocus(self: *Form) void {
        for (self.items.items) |field| if (field.entry) |entry| entry.focus(!self.closed and self.active(field.id) and self.focus == field.id);
    }
    fn optionHit(self: *const Form, x: f64, y: f64) ?usize {
        const id = self.expanded orelse return null;
        const field = self.items.items[id];
        const top = self.optionTop(field);
        if (x < 24 or x >= @as(f64, @floatFromInt(self.width - 24)) or y < top) return null;
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
        if (self.closed or !self.active(id)) return;
        const field = self.get(id);
        switch (field.kind) {
            .button => self.action(self.context, id),
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
        if (self.closed) return false;
        if (symbol == 0xff1b) {
            if (self.expanded != null) {
                self.expanded = null;
                self.relayout();
            } else c.gtk_widget_destroy(self.window);
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
                if (self.layout == null) c.gtk_adjustment_clamp_page(c.gtk_scrolled_window_get_vadjustment(cast(c.GtkScrolledWindow, self.scroll)), top, top + 36);
                self.redraw();
            } else self.activate(id);
            return true;
        }
        if (field.entry) |entry| {
            if (entry.key(symbol, modifiers)) return true;
            const codepoint = c.gdk_keyval_to_unicode(symbol);
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
    fn destroyed(_: *c.GtkWidget, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Form, ptr);
        self.closed = true;
        self.updateFocus();
    }
    fn key(_: *c.GtkWidget, event: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Form, ptr);
        var symbol: c.guint = 0;
        var modifiers: c.GdkModifierType = 0;
        _ = c.gdk_event_get_keyval(event, &symbol);
        _ = c.gdk_event_get_state(event, &modifiers);
        if (self.shortcut) |callback| if (callback(self.context, symbol, modifiers)) return 1;
        if (self.focus) |id| if (self.active(id)) if (self.get(id).entry) |entry| if (entry.filter(event)) return 1;
        return @intFromBool(self.handleKey(symbol, modifiers));
    }
    fn keyRelease(_: *c.GtkWidget, event: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Form, ptr);
        if (self.focus) |id| if (self.active(id)) if (self.get(id).entry) |entry| return @intFromBool(entry.filter(event));
        return 0;
    }
    fn focusIn(_: *c.GtkWidget, _: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
        cast(Form, ptr).updateFocus();
        return 0;
    }
    fn focusOut(_: *c.GtkWidget, _: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Form, ptr);
        self.pressed = null;
        for (self.items.items) |field| if (field.entry) |entry| entry.focus(false);
        return 0;
    }
    fn press(widget: *c.GtkWidget, event: *c.GdkEventButton, ptr: c.gpointer) callconv(.c) c.gboolean {
        if (event.button != 1) return 0;
        const self = cast(Form, ptr);
        self.input_modifiers = event.state;
        if (widget != self.footer) if (self.optionHit(event.x, event.y)) |index| {
            self.option_cursor = index;
            self.pressed = self.expanded;
            return 1;
        };
        const id = self.hitSurface(event.x, event.y, widget == self.footer) orelse {
            self.expanded = null;
            self.relayout();
            return 0;
        };
        if (event.type == 5) if (self.double_clicked) |callback| {
            self.pressed = null;
            callback(self.context, id);
            return 1;
        };
        if (self.expanded != null and self.expanded != id) {
            self.expanded = null;
            self.relayout();
        }
        self.pressed = id;
        self.focusItem(id);
        c.gtk_widget_grab_focus(self.canvas);
        if (self.get(id).entry) |entry| {
            entry.dragging = true;
            entry.point(event.x, event.state & c.GDK_SHIFT_MASK != 0);
        }
        return 1;
    }
    fn release(widget: *c.GtkWidget, event: *c.GdkEventButton, ptr: c.gpointer) callconv(.c) c.gboolean {
        if (event.button != 1) return 0;
        const self = cast(Form, ptr);
        const id = self.pressed orelse return 0;
        self.pressed = null;
        if (self.get(id).entry) |entry| {
            entry.dragging = false;
            return 1;
        }
        if (self.expanded == id) if (self.optionHit(event.x, event.y)) |index| {
            if (index == self.option_cursor) {
                _ = self.select(id, self.get(id).options.items[index].id);
                self.expanded = null;
                self.relayout();
                self.changed(self.context, id);
            }
            return 1;
        };
        if (self.hitSurface(event.x, event.y, widget == self.footer) == id) self.activate(id);
        return 1;
    }
    fn motion(widget: *c.GtkWidget, event: *c.GdkEventMotion, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Form, ptr);
        self.hover = self.hitSurface(event.x, event.y, widget == self.footer);
        if (self.focus) |id| if (self.get(id).entry) |entry| if (entry.dragging) entry.point(event.x, true);
        self.redraw();
        return 1;
    }
    fn scrollEvent(_: *c.GtkWidget, event: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Form, ptr);
        const callback = self.scrolled orelse return 0;
        var direction: c.GdkScrollDirection = 0;
        var dx: f64 = 0;
        var dy: f64 = 0;
        if (c.gdk_event_get_scroll_deltas(event, &dx, &dy) == 0) {
            _ = c.gdk_event_get_scroll_direction(event, &direction);
            dy = if (direction == c.GDK_SCROLL_UP) -1 else 1;
        }
        callback(self.context, dy * 72);
        return 1;
    }
    fn draw(widget: *c.GtkWidget, cr: *c.cairo_t, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Form, ptr);
        self.paint(cr, widget == self.footer) catch {};
        return 1;
    }
    fn makeMask(self: *Form, value: [:0]const u8, width: u32, bold: bool) !text.Mask {
        const scale: f64 = @floatFromInt(self.scale);
        return self.renderer.renderLayout(a, value, .{ .font = if (bold) "Adwaita Sans Bold" else "Adwaita Sans", .size = (if (bold) @as(f64, 15) else 14) * scale, .dpi = 96 * scale, .width = width * self.scale, .lines = 2, .ellipsize = true, .origin = .top });
    }
    const PaintContext = struct {
        form: *Form,
        scale: u32,
        footer: bool,
        fn paint(ctx: @This(), target: raster.Buffer) !void {
            try ctx.form.paintPixels(target, ctx.scale, ctx.footer);
        }
    };
    fn paint(self: *Form, cr: *c.cairo_t, footer: bool) !void {
        const scale: u32 = @intCast(@max(1, c.gtk_widget_get_scale_factor(self.canvas)));
        const width: u32 = @intCast(@max(480, c.gtk_widget_get_allocated_width(self.canvas)));
        self.prepareLayout(width, scale);
        const height: u32 = if (footer) self.footer_height else @intCast(@max(@as(c_int, @intCast(self.height)), c.gtk_widget_get_allocated_height(self.canvas)));
        try c.__zig.paintCairo(cr, width, height, scale, PaintContext{ .form = self, .scale = scale, .footer = footer }, PaintContext.paint);
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
fn color(rgb: u32) raster.Color {
    return raster.Color.rgb(rgb, 1);
}
fn drawText(canvas: raster.Canvas, mask_value: text.Mask, x: f64, y: f64, tint: u32) void {
    mask_value.paint(canvas, x, y, color(tint));
}

test "native forms preserve selections, isolate passwords and navigate controls" {
    c.gtk_init(null, null);
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
    var event = std.mem.zeroes(c.GdkEventButton);
    event.type = c.GDK_BUTTON_PRESS;
    event.button = 1;
    event.x = form.get(toggle).bounds.x + 10;
    event.y = form.get(toggle).bounds.y + 10;
    var handled: c.gboolean = 0;
    c.g_signal_emit_by_name(form.canvas, "button-press-event", &event, &handled);
    event.type = 7;
    c.g_signal_emit_by_name(form.canvas, "button-release-event", &event, &handled);
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
    event.type = c.GDK_BUTTON_PRESS;
    event.x = form.get(pinned).bounds.x + 10;
    event.y = form.get(pinned).bounds.y + 10;
    c.g_signal_emit_by_name(form.footer, "button-press-event", &event, &handled);
    event.type = 7;
    c.g_signal_emit_by_name(form.footer, "button-release-event", &event, &handled);
    try std.testing.expectEqual(@as(usize, 2), callbacks.actions);
    const late_field = try form.add(.entry, "Additional property", "", false);
    form.setEnabled(true);
    form.focusItem(late_field);
    try std.testing.expect(form.handleKey(0xff09, 0));
    try std.testing.expectEqual(pinned, form.focus.?);
    c.gtk_widget_destroy(form.window);
    try std.testing.expect(form.closed);
}
