//! Layer-shell host for the desktop's GTK widgets.
const std = @import("std");
const widgets = @import("desktop-widgets.zig");
const c = widgets.c;
const allocator = std.heap.page_allocator;

fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}

pub const Config = struct {
    height: u16 = 32,
    left: []const widgets.Options = &.{},
    center: []const widgets.Options = &.{},
    right: []const widgets.Options = &.{},
};

const Panel = struct {
    monitor: *c.GdkMonitor,
    window: *c.GtkWidget,
    modules: std.ArrayList(*widgets.Module) = .empty,

    fn group(self: *Panel, options: []const widgets.Options) *c.GtkWidget {
        const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        for (options) |option| {
            const root = c.gtk_event_box_new();
            c.gtk_widget_add_events(root, c.GDK_BUTTON_PRESS_MASK);
            const module = widgets.init(root, option);
            self.modules.append(allocator, module) catch @panic("out of memory");
            if (option.on_click) |command| {
                _ = c.g_signal_connect_data(root, "button-press-event", @ptrCast(&launch), @constCast(command.ptr), null, 0);
            }
            c.gtk_box_pack_start(cast(c.GtkBox, box), root, 0, 0, 0);
        }
        return box;
    }

    fn create(monitor: *c.GdkMonitor, config: Config) *Panel {
        const self = allocator.create(Panel) catch @panic("out of memory");
        self.* = .{ .monitor = monitor, .window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL) };
        _ = c.g_object_ref(monitor);
        const window = cast(c.GtkWindow, self.window);
        c.gtk_widget_set_name(self.window, "desktop-panel");
        c.gtk_window_set_title(window, "Desktop Panel");
        c.gtk_window_set_resizable(window, 0);
        c.gtk_widget_set_size_request(self.window, -1, config.height);
        c.gtk_layer_init_for_window(window);
        c.gtk_layer_set_namespace(window, "desktop-panel");
        c.gtk_layer_set_monitor(window, monitor);
        c.gtk_layer_set_layer(window, c.GTK_LAYER_SHELL_LAYER_TOP);
        c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_TOP, 1);
        c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_LEFT, 1);
        c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_RIGHT, 1);
        c.gtk_layer_set_keyboard_mode(window, c.GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND);
        c.gtk_layer_auto_exclusive_zone_enable(window);
        const layout = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_box_pack_start(cast(c.GtkBox, layout), self.group(config.left), 0, 0, 0);
        c.gtk_box_set_center_widget(cast(c.GtkBox, layout), self.group(config.center));
        c.gtk_box_pack_end(cast(c.GtkBox, layout), self.group(config.right), 0, 0, 0);
        c.gtk_container_add(cast(c.GtkContainer, self.window), layout);
        c.gtk_widget_show_all(self.window);
        return self;
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
    config: Config,
    panels: std.ArrayList(*Panel) = .empty,

    fn add(_: *c.GdkDisplay, monitor: *c.GdkMonitor, data: c.gpointer) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.panels.append(allocator, Panel.create(monitor, self.config)) catch @panic("out of memory");
    }

    fn remove(_: *c.GdkDisplay, monitor: *c.GdkMonitor, data: c.gpointer) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        for (self.panels.items, 0..) |panel, i| {
            if (panel.monitor == monitor) {
                _ = self.panels.orderedRemove(i);
                panel.destroy();
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

fn quit(_: c.gpointer) callconv(.c) c.gboolean {
    c.gtk_main_quit();
    return 1; // Keep source alive until cleanup removes it.
}

pub fn main(process_init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const args = try process_init.minimal.args.toSlice(arena.allocator());
    if (args.len != 3) {
        std.debug.print("Usage: desktop-panel CONFIG.json STYLE.css\n", .{});
        return error.InvalidArguments;
    }
    const config_path = try arena.allocator().dupeSentinel(u8, args[1], 0);
    var contents: [*c]u8 = null;
    var length: c.gsize = 0;
    var err: [*c]c.GError = null;
    if (c.g_file_get_contents(config_path, &contents, &length, &err) == 0) {
        std.debug.print("Cannot read panel configuration: {s}\n", .{err.*.message});
        c.g_clear_error(&err);
        return error.InvalidConfig;
    }
    defer c.g_free(contents);
    const parsed = try std.json.parseFromSlice(Config, arena.allocator(), contents[0..length], .{});
    defer parsed.deinit();
    if (parsed.value.height == 0) return error.InvalidConfig;
    _ = c.g_setenv("GDK_BACKEND", "wayland", 1);
    if (c.gtk_init_check(null, null) == 0) return error.NoWaylandDisplay;
    if (c.gtk_layer_is_supported() == 0) return error.LayerShellUnavailable;
    const style_path = try arena.allocator().dupeSentinel(u8, args[2], 0);
    const provider = c.gtk_css_provider_new();
    defer c.g_object_unref(provider);
    if (c.gtk_css_provider_load_from_path(provider, style_path, &err) == 0) {
        std.debug.print("Cannot load panel stylesheet: {s}\n", .{err.*.message});
        c.g_clear_error(&err);
        return error.InvalidStyle;
    }
    c.gtk_style_context_add_provider_for_screen(c.gdk_screen_get_default(), cast(c.GtkStyleProvider, provider), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    var app = App{ .config = parsed.value };
    const display = c.gdk_display_get_default().?;
    const added = c.g_signal_connect_data(display, "monitor-added", @ptrCast(&App.add), &app, null, 0);
    const removed = c.g_signal_connect_data(display, "monitor-removed", @ptrCast(&App.remove), &app, null, 0);
    defer {
        c.g_signal_handler_disconnect(display, added);
        c.g_signal_handler_disconnect(display, removed);
        for (app.panels.items) |panel| panel.destroy();
        app.panels.deinit(allocator);
        // Complete cancelled asynchronous reads while their module refs remain valid.
        while (c.g_main_context_iteration(null, 0) != 0) {}
    }
    const count = c.gdk_display_get_n_monitors(display);
    var i: c_int = 0;
    while (i < count) : (i += 1) App.add(display, c.gdk_display_get_monitor(display, i).?, &app);
    const term = c.g_unix_signal_add(c.SIGTERM, &quit, null);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &quit, null);
    defer _ = c.g_source_remove(term);
    defer _ = c.g_source_remove(interrupt);
    c.gtk_main();
}
