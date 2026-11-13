//! Layer-shell windows hosting the panel's native pixel views.
const layer = @import("desktop-layer-shell.zig");
const p = @import("desktop-protocols.zig");
const std = @import("std");
const widgets = @import("desktop-widgets.zig");
const c = widgets.c;
const allocator = std.heap.page_allocator;

const cast = c.__zig.cast;

pub const Config = struct {
    height: u16 = 32,
    left: []const widgets.Options = &.{},
    center: []const widgets.Options = &.{},
    right: []const widgets.Options = &.{},
};

const Panel = struct {
    devices: *@import("desktop-devices.zig").Service,
    monitor: *c.GdkMonitor,
    window: *c.GtkWidget,
    modules: std.ArrayList(*widgets.Module) = .empty,

    fn group(self: *Panel, options: []const widgets.Options) *c.GtkWidget {
        const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        for (options) |option| {
            const root = c.gtk_event_box_new();
            c.gtk_widget_add_events(root, c.GDK_BUTTON_PRESS_MASK);
            const module = widgets.initWithDevices(root, option, self.devices);
            self.modules.append(allocator, module) catch @panic("out of memory");
            if (option.on_click) |command| {
                _ = c.g_signal_connect_data(root, "button-press-event", @ptrCast(&launch), @constCast(command.ptr), null, 0);
            }
            c.gtk_box_pack_start(cast(c.GtkBox, box), root, 0, 0, 0);
        }
        return box;
    }

    fn create(monitor: *c.GdkMonitor, config: Config, devices: *@import("desktop-devices.zig").Service) *Panel {
        const self = allocator.create(Panel) catch @panic("out of memory");
        self.* = .{ .devices = devices, .monitor = monitor, .window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL) };
        _ = c.g_object_ref(monitor);
        const window = cast(c.GtkWindow, self.window);
        c.gtk_widget_set_name(self.window, "desktop-panel");
        c.gtk_window_set_title(window, "Desktop Panel");
        c.gtk_window_set_resizable(window, 0);
        c.gtk_widget_set_size_request(self.window, -1, config.height);
        layer.init_for_window(window);
        layer.set_namespace(window, "desktop-panel");
        layer.set_monitor(window, monitor);
        layer.set_layer(window, .top);
        layer.set_anchor(window, .top, 1);
        layer.set_anchor(window, .left, 1);
        layer.set_anchor(window, .right, 1);
        layer.set_keyboard_mode(window, .on_demand);
        layer.auto_exclusive_zone_enable(window);
        const layout = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_box_pack_start(cast(c.GtkBox, layout), self.group(config.left), 0, 0, 0);
        c.gtk_box_set_center_widget(cast(c.GtkBox, layout), self.group(config.center));
        c.gtk_box_pack_end(cast(c.GtkBox, layout), self.group(config.right), 0, 0, 0);
        c.gtk_container_add(cast(c.GtkContainer, self.window), layout);
        if (c.gdk_screen_get_rgba_visual(c.gtk_widget_get_screen(self.window))) |visual| c.gtk_widget_set_visual(self.window, visual);
        c.gtk_widget_show_all(self.window);
        return self;
    }

    fn applyOverview(self: *Panel, active: bool, workspace_count: u8, workspace_active: u8) void {
        const ctx = c.gtk_widget_get_style_context(self.window);
        if (active) c.gtk_style_context_add_class(ctx, "overview") else c.gtk_style_context_remove_class(ctx, "overview");
        c.gtk_widget_queue_draw(self.window);
        for (self.modules.items) |module| widgets.setOverviewState(module, active, workspace_count, workspace_active);
    }

    fn destroy(self: *Panel) void {
        // Cancel callbacks before their widgets or monitor disappear.
        for (self.modules.items) |module| widgets.deinit(module);
        self.modules.deinit(allocator);
        c.gtk_widget_destroy(self.window);
        c.g_object_unref(self.monitor);
        allocator.destroy(self);
    }
};

const App = struct {
    devices: *@import("desktop-devices.zig").Service,
    config: Config,
    panels: std.ArrayList(*Panel) = .empty,
    revision: u64 = 0,
    overview_active: bool = false,
    workspace_count: u8 = 2,
    workspace_active: u8 = 0,
    pending_count: u8 = 0,
    pending_active: u8 = 0,
    registry: ?*c.wl_registry = null,
    overview: ?*p.dotfiles_overview_v1 = null,

    fn syncPanels(self: *App) void {
        for (self.panels.items) |panel| panel.applyOverview(self.overview_active, self.workspace_count, self.workspace_active);
    }

    fn connectOverview(self: *App, display: *c.GdkDisplay) void {
        const wire = c.gdk_wayland_display_get_wl_display(display) orelse return;
        const registry = c.wl_display_get_registry(wire) orelse return;
        self.registry = registry;
        _ = c.wl_registry_add_listener(registry, &registry_listener, self);
        _ = c.wl_display_roundtrip(wire);
    }

    fn deinitOverview(self: *App) void {
        if (self.overview) |overview| p.dotfiles_overview_v1_destroy(overview);
        if (self.registry) |registry| c.wl_registry_destroy(registry);
        self.overview = null;
        self.registry = null;
    }

    fn onGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        if (self.overview == null and version >= 2 and std.mem.eql(u8, std.mem.span(interface), "dotfiles_overview_v1")) {
            self.overview = @ptrCast(c.wl_registry_bind(registry, name, &p.dotfiles_overview_v1_interface, 2));
            if (self.overview) |overview| _ = p.dotfiles_overview_v1_add_listener(overview, &overview_listener, self);
        }
    }

    fn onGlobalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

    fn onWorkspace(data: ?*anyopaque, _: ?*p.dotfiles_overview_v1, index: u32, _: [*c]const u8, active: u32) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.pending_count = @max(self.pending_count, @as(u8, @intCast(@min(index + 1, 16))));
        if (active != 0) self.pending_active = @intCast(@min(index, 15));
    }

    fn onWindow(_: ?*anyopaque, _: ?*p.dotfiles_overview_v1, _: [*c]const u8, _: u32, _: i32, _: i32, _: i32, _: i32, _: u32) callconv(.c) void {}

    fn onDone(data: ?*anyopaque, _: ?*p.dotfiles_overview_v1) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        if (self.pending_count > 0) {
            self.workspace_count = self.pending_count;
            self.workspace_active = @min(self.pending_active, self.workspace_count - 1);
            self.pending_count = 0;
            self.pending_active = 0;
            self.syncPanels();
        }
    }

    fn onOverview(data: ?*anyopaque, _: ?*p.dotfiles_overview_v1, active: u32) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const next = active != 0;
        if (self.overview_active == next) return;
        self.overview_active = next;
        self.syncPanels();
    }

    const registry_listener: c.wl_registry_listener = .{ .global = &onGlobal, .global_remove = &onGlobalRemove };
    const overview_listener: p.dotfiles_overview_v1_listener = .{
        .workspace = &onWorkspace,
        .window = &onWindow,
        .done = &onDone,
        .overview = &onOverview,
    };

    fn add(_: *c.GdkDisplay, monitor: *c.GdkMonitor, data: c.gpointer) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const panel = Panel.create(monitor, self.config, self.devices);
        panel.applyOverview(self.overview_active, self.workspace_count, self.workspace_active);
        self.panels.append(allocator, panel) catch @panic("out of memory");
        self.revision +%= 1;
    }

    fn remove(_: *c.GdkDisplay, monitor: *c.GdkMonitor, data: c.gpointer) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        for (self.panels.items, 0..) |panel, i| {
            if (panel.monitor == monitor) {
                _ = self.panels.orderedRemove(i);
                panel.destroy();
                self.revision +%= 1;
                return;
            }
        }
    }
};

fn launch(root: *c.GtkWidget, event: *c.GdkEventButton, data: c.gpointer) callconv(.c) c.gboolean {
    if (event.button != 1) return 0;
    widgets.settings_launch(cast(c.GtkButton, root), data);
    return 1;
}

/// Owns panel windows; the session owns GTK and the event loop.
pub const Service = struct {
    arena: std.heap.ArenaAllocator,
    app: App,
    added: c.gulong = 0,
    removed: c.gulong = 0,

    pub fn create(config_path: [:0]const u8, devices: *@import("desktop-devices.zig").Service) !*Service {
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var contents: [*c]u8 = null;
        var length: c.gsize = 0;
        if (c.g_file_get_contents(config_path, &contents, &length, null) == 0) return error.InvalidConfig;
        defer c.g_free(contents);
        const parsed = try std.json.parseFromSlice(Config, arena.allocator(), contents[0..length], .{});
        if (parsed.value.height == 0) return error.InvalidConfig;
        widgets.ensureStyle();
        self.* = .{ .arena = arena, .app = .{ .config = parsed.value, .devices = devices } };
        const display = c.gdk_display_get_default().?;
        self.app.connectOverview(display);
        self.added = c.g_signal_connect_data(display, "monitor-added", @ptrCast(&App.add), &self.app, null, 0);
        self.removed = c.g_signal_connect_data(display, "monitor-removed", @ptrCast(&App.remove), &self.app, null, 0);
        var i: c_int = 0;
        while (i < c.gdk_display_get_n_monitors(display)) : (i += 1) App.add(display, c.gdk_display_get_monitor(display, i).?, &self.app);
        return self;
    }

    pub fn revision(self: *Service) u64 {
        return self.app.revision;
    }

    pub fn update(self: *Service, source: []const u8, value: @import("desktop-panel-data.zig").Update) void {
        for (self.app.panels.items) |panel| for (panel.modules.items) |module| {
            if (std.mem.eql(u8, std.mem.span(module.source), source)) widgets.update(module, value);
        };
    }

    pub fn destroy(self: *Service) void {
        const display = c.gdk_display_get_default().?;
        c.g_signal_handler_disconnect(display, self.added);
        c.g_signal_handler_disconnect(display, self.removed);
        self.app.deinitOverview();
        for (self.app.panels.items) |panel| panel.destroy();
        self.app.panels.deinit(allocator);
        self.arena.deinit();
        allocator.destroy(self);
    }
};
