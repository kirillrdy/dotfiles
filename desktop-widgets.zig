//! Panel data and actions, with shared native popup controllers.
const std = @import("std");
const panel_data = @import("desktop-panel-data.zig");
const power_backend = @import("desktop-power.zig");
const raster = @import("desktop-raster.zig");
const popup = @import("desktop-popup.zig");
const wire = @import("desktop-surface.zig");
const quick = @import("desktop-quick-settings.zig");
pub const date_menu = @import("desktop-date-menu.zig");
pub const c = @import("desktop-glib.zig");
const DateTime = @import("desktop-datetime.zig").DateTime;
pub const native = @import("desktop-panel-view.zig");
const dbus = @import("dbus");
const loop = @import("desktop-dbus-loop.zig");
const notifications: dbus.Connection.Call = .{ .destination = "org.freedesktop.Notifications", .path = "/org/freedesktop/Notifications", .interface = "org.dotfiles.Notifications", .member = "" };
const cast = c.__zig.cast;
pub const Options = struct {
    name: [:0]const u8 = "",
    kind: [:0]const u8 = "indicator",
    source: [:0]const u8 = "",
    on_click: ?[:0]const u8 = null,
    network_settings_command: ?[:0]const u8 = null,
    sound_settings_command: [:0]const u8 = "desktop-zig settings sound",
};
pub const Module = struct {
    allocator: std.mem.Allocator,
    refs: c.gint = 1,
    dead: c.gboolean = 0,
    monitors: c.gboolean = 0,
    status: c.gboolean = 0,
    date_controls: ?*date_menu.Controls = null,
    history_subscription: u32 = 0,
    history_serial: u32 = 0,
    history_busy: bool = false,
    history_dirty: bool = false,
    source: [*:0]const u8 = "",
    cancel: [*c]c.GCancellable = null,
    clock_timer: c.guint = 0,
    power_timer: c.guint = 0,
    /// The shared session bus, for notification history and device-change signals.
    bus: ?*loop.Source = null,
    device_subscription: u32 = 0,
    settings_subscription: u32 = 0,
    quick: ?*quick.Controls = null,
    power_pending: c.gboolean = 0,
    usage_menu: ?*UsagePopup = null,
    view: native.View = .{},
    usage: native.Usage = .{},
    tooltip: [*c]u8 = null,
    on_redraw: ?*const fn (?*anyopaque) void = null,
    redraw_context: ?*anyopaque = null,
};

/// Native popup controller using the module's existing usage view.
pub const UsagePopup = struct {
    module: *Module,
    popup: popup.Host = undefined,

    fn create(module: *Module) !*UsagePopup {
        const self = try module.allocator.create(UsagePopup);
        self.* = .{ .module = module };
        self.popup = .{
            .allocator = module.allocator,
            .context = self,
            .namespace = "desktop-usage",
            .paint = &draw,
            .input = .{ .button = &button, .motion = &motion, .leave = &leave, .symbol = &key },
            .resized = &resized,
            .dismiss = &dismiss,
        };
        return self;
    }
    fn destroy(self: *UsagePopup) void {
        self.popup.deinit();
        self.module.allocator.destroy(self);
    }
    pub fn show(self: *UsagePopup, global_x: i32, global_y: i32) !void {
        try self.popup.prepare(global_x, global_y);
        const view = &self.module.usage;
        try view.prepare(self.module.allocator, self.popup.surface.?.output.scale);
        view.pressed = false;
        view.hovered = false;
        view.keyboard_focus = true;
        self.popup.place(view.width, view.height);
        try self.popup.show();
    }
    pub fn hide(self: *UsagePopup) void {
        self.popup.hide();
        self.module.usage.pressed = false;
        self.module.usage.hovered = false;
    }
    fn redraw(self: *UsagePopup) void {
        self.popup.redraw();
    }
    fn dismiss(ptr: ?*anyopaque) void {
        cast(UsagePopup, ptr).hide();
    }
    fn resized(ptr: ?*anyopaque) void {
        cast(UsagePopup, ptr).redraw();
    }
    fn draw(ptr: ?*anyopaque, target: wire.Pixels) void {
        const self = cast(UsagePopup, ptr);
        @memset(target.pixels, 0);
        self.paint(target) catch |err| {
            std.log.err("Usage paint: {s}", .{@errorName(err)});
            self.popup.requestHide();
        };
    }
    fn paint(self: *UsagePopup, target: wire.Pixels) !void {
        const view = &self.module.usage;
        try view.prepare(self.module.allocator, self.popup.surface.?.buffer_scale);
        view.paint(try self.popup.canvas(view.width, view.height));
        try self.popup.blit(target);
    }
    fn onRefresh(self: *const UsagePopup, x: f64, y: f64) bool {
        const local = self.popup.point(x, y);
        return self.module.usage.refreshRect().contains(local.x, local.y);
    }
    fn button(ptr: ?*anyopaque, _: *wire.Surface, code: u32, pressed: bool, x: f64, y: f64) void {
        const self = cast(UsagePopup, ptr);
        if (!self.popup.visible or self.popup.close_idle != 0 or code != 272) return;
        if (pressed and !self.popup.contains(x, y)) {
            self.popup.requestHide();
            return;
        }
        const view = &self.module.usage;
        const hit = self.onRefresh(x, y);
        if (pressed) {
            view.keyboard_focus = false;
            view.pressed = view.enabled and hit;
        } else {
            const activate = view.pressed and hit;
            view.pressed = false;
            if (activate) usage_refresh(self.module);
        }
        self.redraw();
    }
    fn motion(ptr: ?*anyopaque, _: *wire.Surface, x: f64, y: f64) void {
        const self = cast(UsagePopup, ptr);
        if (!self.popup.visible or self.popup.close_idle != 0) return;
        const hovered = self.onRefresh(x, y);
        if (self.module.usage.hovered != hovered) {
            self.module.usage.hovered = hovered;
            self.redraw();
        }
    }
    fn leave(ptr: ?*anyopaque, _: *wire.Surface) void {
        const self = cast(UsagePopup, ptr);
        self.module.usage.hovered = false;
        self.redraw();
    }
    fn key(ptr: ?*anyopaque, _: *wire.Surface, symbol: u32, _: u32, pressed: bool) bool {
        return !pressed or cast(UsagePopup, ptr).handleKey(symbol);
    }
    pub fn handleKey(self: *UsagePopup, symbol: u32) bool {
        if (!self.popup.visible or self.popup.close_idle != 0) return true;
        switch (symbol) {
            0xff1b => self.popup.requestHide(),
            0xff09, 0xfe20 => self.module.usage.keyboard_focus = true,
            0xff0d, 0xff8d, 0x20 => usage_refresh(self.module),
            else => return false,
        }
        self.redraw();
        return true;
    }
};

pub fn unref_module(m: *Module) callconv(.c) void {
    m.refs -= 1;
    if (m.refs != 0) return;
    if (m.cancel != null) c.g_object_unref(m.cancel);
    c.g_free(m.tooltip);
    m.view.deinit(m.allocator);
    m.usage.deinit(m.allocator);
    m.allocator.destroy(m);
}
pub var power_ids: [3][*c]const u8 = [3][*c]const u8{
    "performance",
    "balanced",
    "power-saver",
};
pub fn apply_power_state(m: *Module, state: power_backend.State) void {
    if (m.quick) |controls| {
        controls.setPowerState(state, m.power_pending != 0);
        const available = state.available[0] or state.available[1] or state.available[2];
        if (!available) controls.setMessage("Power profiles unavailable") else if (std.mem.eql(u8, controls.view.model.message.slice(), "Power profiles unavailable")) controls.setMessage("");
        return;
    }
}
pub fn update_power(m: *Module) callconv(.c) void {
    apply_power_state(m, (power_backend.Backend{}).inspect(m.allocator));
}
fn refresh_power(data: c.gpointer) callconv(.c) c.gboolean {
    const m: *Module = @ptrCast(@alignCast(data));
    if (m.dead != 0) return 0;
    update_power(m);
    return 1;
}
fn set_power_message(m: *Module, message: [*c]const u8) void {
    if (m.quick) |controls| controls.setMessage(std.mem.span(message));
}
fn native_profile_selected(data: ?*anyopaque, index: usize) void {
    if (index < 3) select_power(cast(Module, data), power_ids[index]);
}
pub fn power_set_ready(source: ?*c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const m: *Module = @ptrCast(@alignCast(data));
    var err: [*c]c.GError = null;
    var errors: [*c]u8 = null;
    const process: *c.GSubprocess = @ptrCast(@alignCast(source));
    const communicated = c.g_subprocess_communicate_utf8_finish(process, result, null, &errors, &err) != 0;
    defer c.g_clear_error(&err);
    defer c.g_free(errors);
    if (m.dead == 0) {
        m.power_pending = 0;
        update_power(m);
        set_power_message(m, if (err != null) err.*.message else if (!communicated or c.g_subprocess_get_successful(process) == 0) (if (errors != null and errors[0] != 0) errors else "Could not change the power profile") else "");
    }
    unref_module(m);
}
fn select_power(m: *Module, id: [*c]const u8) void {
    if (m.dead != 0 or m.power_pending != 0) return;
    const helper = c.__zig.getenv("DESKTOP_POWER_HELPER");
    const pkexec = c.__zig.getenv("DESKTOP_POWER_PKEXEC");
    if (helper == null or pkexec == null) {
        set_power_message(m, "Power profile helper unavailable");
        return;
    }
    var err: [*c]c.GError = null;
    const argv = [_][*c]const u8{ pkexec, helper, "power", "set", id, null };
    const process = c.g_subprocess_newv(&argv, c.G_SUBPROCESS_FLAGS_STDERR_PIPE | c.G_SUBPROCESS_FLAGS_STDOUT_SILENCE, &err);
    if (process == null) {
        set_power_message(m, if (err != null) err.*.message else "Could not start the power profile helper");
        c.g_clear_error(&err);
        return;
    }
    defer c.g_object_unref(process);
    m.power_pending = 1;
    update_power(m);
    set_power_message(m, "Switching…");
    m.refs += 1;
    c.g_subprocess_communicate_utf8_async(process, null, m.cancel, &power_set_ready, m);
}
pub fn update_clock(data: c.gpointer) callconv(.c) c.gboolean {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    var buffer: [64]u8 = undefined;
    if (DateTime.now()) |now| if (now.format(&buffer, "%b %-d %H:%M")) |label| {
        if (!std.mem.eql(u8, m.view.clock.value, label)) {
            m.view.clock.set(m.allocator, label);
            resize(m);
        }
    } else |_| {} else |_| {}
    if (m.date_controls) |controls| controls.tick();
    return 1;
}
pub fn make_calendar(m: *Module) callconv(.c) void {
    m.date_controls = date_menu.Controls.create(m.allocator, .{
        .context = m,
        .clear = &history_clear,
        .dismiss = &history_dismiss,
        .activate = &history_activate,
        .closed = &calendar_closed,
    }) catch @panic("cannot create date menu");
}
pub fn historyOpen(m: *Module, open: bool) void {
    if (open) history_reload(m);
    history_call(m, "CalendarOpen", .{open});
}
fn calendar_closed(data: ?*anyopaque) void {
    const m: *Module = @ptrCast(@alignCast(data));
    history_call(m, "CalendarOpen", .{false});
}
/// Sends a history request whose reply is not needed.
fn history_call(m: *Module, member: []const u8, args: anytype) void {
    if (m.dead != 0) return;
    const bus = m.bus orelse return;
    var target = notifications;
    target.member = member;
    bus.connection.send(target, args) catch {};
}
fn history_clear(data: ?*anyopaque) void {
    history_call(@ptrCast(@alignCast(data)), "Clear", .{});
}
fn history_dismiss(data: ?*anyopaque, id: u32) void {
    history_call(@ptrCast(@alignCast(data)), "Dismiss", .{id});
}
fn history_activate(data: ?*anyopaque, id: u32, key: [:0]const u8) void {
    history_call(@ptrCast(@alignCast(data)), "Activate", .{ id, @as([]const u8, key) });
}
fn history_changed(data: ?*anyopaque, _: *const dbus.Message) void {
    history_reload(@ptrCast(@alignCast(data)));
}
fn history_reload(m: *Module) void {
    if (m.dead != 0) return;
    const bus = m.bus orelse return;
    if (m.history_busy) {
        m.history_dirty = true;
        return;
    }
    var target = notifications;
    target.member = "List";
    m.history_serial = bus.connection.call(target, .{}, 2000, &history_ready, m) catch return;
    m.history_busy = true;
    m.history_dirty = false;
}
/// Teardown cancels this call by serial, so the module is alive whenever it runs.
fn history_ready(data: ?*anyopaque, reply: dbus.Reply) void {
    const m: *Module = @ptrCast(@alignCast(data));
    m.history_serial = 0;
    m.history_busy = false;
    switch (reply) {
        .ok => |message| if (message.read(struct { []const u8 })) |value| {
            if (m.date_controls) |controls| controls.load(value[0]);
        } else |_| {},
        .failed => {},
    }
    if (m.history_dirty) history_reload(m);
}
pub fn usage_refresh(m: *Module) void {
    const source = std.mem.span(m.source);
    if (m.dead != 0 or !m.usage.enabled or !panel_data.isUsage(source)) return;
    m.usage.enabled = false;
    m.usage.checked.set(m.allocator, "Refreshing…");
    if (m.usage_menu) |menu| menu.redraw();
    if (m.on_redraw) |cb| cb(m.redraw_context);
    if (refresh_source) |refresh| refresh(source);
}
pub fn make_usage_menu(m: *Module) callconv(.c) void {
    m.usage_menu = UsagePopup.create(m) catch @panic("cannot create usage popup");
}
pub fn update_usage(m: *Module, content: panel_data.Update) void {
    for (0..2) |i| {
        const window: panel_data.Window = if (i < content.windows.len) content.windows[i] else .{};
        const valid = if (window.percent) |p| std.math.isFinite(p) else false;
        const value = if (valid) std.math.clamp(window.percent.?, 0, 100) else 0;
        const label = if (valid) c.g_strdup_printf("%.1f%% remaining", value) else c.g_strdup("—");
        m.usage.percent[i].set(m.allocator, std.mem.span(label));
        c.g_free(@as(c.gpointer, @ptrCast(label)));
        m.usage.values[i] = value;
        m.usage.pace[i] = if (valid) window.pace else null;
        m.usage.reset[i].set(m.allocator, window.reset);
    }
    m.usage.checked.set(m.allocator, if (content.checked.len != 0) content.checked else "Checked: —");
    m.usage.error_label.set(m.allocator, content.@"error");
    m.usage.enabled = true;
    if (m.usage_menu) |menu| menu.redraw();
}
fn update_items(m: *Module, items: []const panel_data.Item) void {
    for (&m.view.items, 0..) |*item, i| {
        item.visible = i < items.len;
        if (!item.visible) continue;
        const value = items[i];
        item.setIcon(m.allocator, value.icon);
        item.label.set(m.allocator, value.text);
        item.tooltip.set(m.allocator, value.tooltip);
        item.command.set(m.allocator, value.command);
    }
}

fn update_graph(a: std.mem.Allocator, g: *native.Graph, graph: panel_data.Graph) bool {
    g.tooltip.set(a, graph.tooltip);
    if (graph.sequence == g.sequence) return false;
    g.sequence = graph.sequence;
    g.series = @intCast(@min(graph.values.len, 5));
    if (g.series == 0) return true;
    g.maximum = graph.maximum;
    g.autoscale = @intFromBool(g.maximum <= 0);
    if (g.count == 100) {
        for (0..5) |row| {
            for (0..99) |col| g.history[row][col] = g.history[row][col + 1];
        }
        g.count -= 1;
    }
    var total: f64 = 0;
    for (0..g.series) |i| {
        const val = graph.values[i];
        total += if (std.math.isFinite(val)) @max(0, val) else 0;
        g.history[i][g.count] = total;
        g.colors[i] = raster.hex(if (i < graph.colors.len) graph.colors[i] else 0xffffff);
    }
    g.count += 1;
    return true;
}

pub fn update(m: *Module, value: panel_data.Update) void {
    var changed = m.monitors == 0;
    if (m.monitors != 0) {
        if (value.monitors) |graphs| for (graphs[0..@min(3, graphs.len)], 0..) |graph, i| {
            if (update_graph(m.allocator, &m.view.graphs[i], graph)) changed = true;
        };
    } else if (value.items) |items| update_items(m, items);
    c.g_free(@as(c.gpointer, @ptrCast(m.tooltip)));
    m.tooltip = c.g_strndup(value.tooltip.ptr, value.tooltip.len);
    if (m.view.usage) update_usage(m, value);
    if (changed) resize(m);
}

test "monitor polling updates tooltips without repainting unchanged graph samples" {
    const Counter = struct {
        fn redraw(ptr: ?*anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(ptr.?));
            count.* += 1;
        }
    };
    var redraws: usize = 0;
    var module: Module = .{ .allocator = std.testing.allocator, .monitors = 1, .view = .{ .monitors = true }, .on_redraw = &Counter.redraw, .redraw_context = &redraws };
    defer module.view.deinit(std.testing.allocator);
    defer c.g_free(module.tooltip);
    var graph: panel_data.Graph = .{ .values = &.{10}, .sequence = 1, .maximum = 100, .tooltip = "first" };
    update(&module, .{ .monitors = &.{graph} });
    try std.testing.expectEqual(@as(usize, 1), redraws);
    graph.tooltip = "new tooltip";
    update(&module, .{ .monitors = &.{graph} });
    try std.testing.expectEqual(@as(usize, 1), redraws);
    try std.testing.expectEqualStrings("new tooltip", module.view.graphs[0].tooltip.value);
    graph.sequence += 1;
    update(&module, .{ .monitors = &.{graph} });
    try std.testing.expectEqual(@as(usize, 2), redraws);
    try std.testing.expectEqual(@as(u32, 2), module.view.graphs[0].count);
}
fn device_changed(data: ?*anyopaque, _: *const dbus.Message) void {
    const m: *Module = @ptrCast(@alignCast(data));
    if (m.dead != 0) return;
    if (m.source[0] != 0) {
        if (refresh_source) |refresh| refresh(std.mem.span(m.source));
    }
}
/// Joins the shared session bus; without one the module works, minus live history and device updates.
fn connect_session(m: *Module) void {
    const bus = loop.acquire(m.allocator, .session) catch |err| {
        std.log.warn("panel: session bus unavailable: {s}", .{@errorName(err)});
        return;
    };
    m.bus = bus;
    const connection = bus.connection;
    if (m.status != 0) {
        m.device_subscription = connection.subscribe(null, "org.dotfiles.DesktopOsd", "DeviceChanged", "/org/dotfiles/DesktopOsd", &device_changed, m) catch 0;
        m.settings_subscription = connection.subscribe(null, "org.dotfiles.DesktopSettings", "DeviceChanged", "/org/dotfiles/DesktopSettings", &device_changed, m) catch 0;
    }
    if (m.date_controls != null) {
        m.history_subscription = connection.subscribe("org.freedesktop.Notifications", "org.dotfiles.Notifications", "Changed", "/org/freedesktop/Notifications", &history_changed, m) catch 0;
        history_reload(m);
    }
}
fn initCommon(m: *Module, options: Options, devices: ?*@import("desktop-devices.zig").Service) void {
    if (m.monitors != 0) {
        resize(m);
    } else if (m.view.usage) {
        const icon = panel_data.usageIcon(options.source);
        update_items(m, &.{.{ .icon = icon, .text = if (icon.len == 0) "Codex…" else "…" }});
        m.tooltip = c.g_strdup_printf("Loading %s usage…", panel_data.usageName(options.source).ptr);
        m.usage.checked.set(m.allocator, "Loading…");
        make_usage_menu(m);
    } else if (m.status != 0) {
        m.quick = quick.Controls.createWithDevices(m.allocator, if (options.network_settings_command) |command| command.ptr else options.sound_settings_command.ptr, options.sound_settings_command.ptr, devices);
        const controls = m.quick.?;
        controls.profile_context = m;
        controls.profile_selected = &native_profile_selected;
        update_power(m);
        m.power_timer = c.g_timeout_add_seconds(2, &refresh_power, m);
        connect_session(m);
    } else if (c.g_strcmp0(options.kind.ptr, "clock") == 0) {
        make_calendar(m);
        connect_session(m);
        _ = update_clock(@as(c.gpointer, @ptrCast(m)));
        m.clock_timer = c.g_timeout_add_seconds(1, &update_clock, @as(c.gpointer, @ptrCast(m)));
    }
    resize(m);
    m.source = options.source.ptr;
}
pub fn init(allocator: std.mem.Allocator, options: Options, devices: ?*@import("desktop-devices.zig").Service, on_redraw: ?*const fn (?*anyopaque) void, redraw_context: ?*anyopaque) *Module {
    const m = allocator.create(Module) catch @panic("out of memory");
    m.* = .{
        .allocator = allocator,
        .cancel = c.g_cancellable_new(),
        .monitors = @intFromBool(std.mem.eql(u8, options.kind, "monitors")),
        .status = @intFromBool(std.mem.eql(u8, options.name, "gnome-status")),
        .view = .{ .monitors = std.mem.eql(u8, options.kind, "monitors"), .status = std.mem.eql(u8, options.name, "gnome-status"), .activities = std.mem.eql(u8, options.kind, "activities"), .usage = std.mem.eql(u8, options.name, "gnome-codex") or std.mem.eql(u8, options.name, "gnome-claude") or std.mem.eql(u8, options.name, "gnome-antigravity"), .disk = std.mem.eql(u8, options.name, "gnome-disk") },
        .on_redraw = on_redraw,
        .redraw_context = redraw_context,
    };
    initCommon(m, options, devices);
    return m;
}

test "usage indicators are visible before either collector returns" {
    const codex = init(std.testing.allocator, .{ .name = "gnome-codex", .source = "codex" }, null, null, null);
    defer deinit(codex);
    const claude = init(std.testing.allocator, .{ .name = "gnome-claude", .source = "claude" }, null, null, null);
    defer deinit(claude);

    update(claude, .{ .items = &.{.{ .text = "72%" }} });
    try std.testing.expectEqualStrings("72%", claude.view.items[0].label.value);
    try std.testing.expect(codex.view.items[0].visible);
    try std.testing.expectEqualStrings("Loading Codex usage…", std.mem.span(codex.tooltip));
    try std.testing.expectEqualStrings("Loading…", codex.usage.checked.value);
    try std.testing.expect(!codex.usage.enabled);

    update(codex, .{ .items = &.{.{ .text = "54%" }} });
    try std.testing.expectEqualStrings("54%", codex.view.items[0].label.value);
    try std.testing.expect(codex.usage.enabled);
}

pub fn deinit(m: *Module) void {
    // Closing a clock during panel/output teardown must restore banners even
    // though its outstanding history requests are about to be cancelled.
    if (m.date_controls != null and m.date_controls.?.popup.visible) history_call(m, "CalendarOpen", .{false});
    m.dead = 1;
    if (m.bus) |bus| {
        // The shared connection outlives this module: drop everything that points back at it.
        const connection = bus.connection;
        if (m.history_serial != 0) connection.cancel(m.history_serial);
        for ([_]u32{ m.device_subscription, m.settings_subscription, m.history_subscription }) |id| {
            if (id != 0) connection.unsubscribe(id);
        }
        m.bus = null;
        loop.release(bus);
    }
    if (m.clock_timer != 0) {
        _ = c.g_source_remove(m.clock_timer);
    }
    if (m.date_controls) |controls| controls.destroy();
    m.date_controls = null;
    if (m.usage_menu) |menu| menu.destroy();
    m.usage_menu = null;
    if (m.quick) |controls| controls.deinit();
    if (m.power_timer != 0) _ = c.g_source_remove(m.power_timer);
    c.g_cancellable_cancel(m.cancel);
    unref_module(m);
}

/// Session callback for built-in collectors; invoked on the GLib thread.
pub var refresh_source: ?*const fn ([]const u8) void = null;

fn resize(m: *Module) void {
    m.view.prepare(m.allocator, @max(1, m.view.scale), 32) catch |err| {
        std.log.err("panel layout: {s}", .{@errorName(err)});
        return;
    };
    if (m.on_redraw) |cb| cb(m.redraw_context);
}
pub fn setOverviewState(m: *Module, active: bool, workspace_count: u8, workspace_active: u8) void {
    const changed = m.view.overview != active or m.view.workspace_count != workspace_count or m.view.workspace_active != workspace_active;
    m.view.overview = active;
    m.view.workspace_count = workspace_count;
    m.view.workspace_active = workspace_active;
    if (changed) if (m.on_redraw) |cb| cb(m.redraw_context);
}
