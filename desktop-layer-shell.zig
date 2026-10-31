//! Layer-shell roles owned by Zig; GTK retains rendering, input and xdg popups.
//! The matching GTK patch calls map/unmap/popup hooks on custom GdkWindows.
//! All dimensions are logical pixels. No private GTK layouts are accessed.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const p = @import("desktop-protocols.zig");
const a = std.heap.page_allocator;
const cast = c.__zig.cast;

pub const Layer = enum(u32) { background, bottom, top, overlay };
pub const Edge = enum { left, right, top, bottom };
pub const KeyboardMode = enum(u32) { none, exclusive, on_demand };
const Proxy = c.struct_wl_proxy;
const state_key = "desktop-layer-state";

fn request(proxy: *Proxy, opcode: u32, args: anytype) void {
    const prefix = .{ proxy, opcode, @as([*c]const c.struct_wl_interface, null), c.wl_proxy_get_version(proxy), @as(u32, 0) };
    _ = @call(.auto, c.wl_proxy_marshal_flags, prefix ++ args);
}

const Connection = struct {
    display: *c.wl_display,
    registry: *c.wl_registry,
    shell: ?*Proxy = null,
    global_name: u32 = 0,

    fn get(display: *c.GdkDisplay) ?*Connection {
        if (c.g_object_get_data(cast(c.GObject, display), "desktop-layer-connection")) |data| return cast(Connection, data);
        const self = a.create(Connection) catch @panic("out of memory");
        const wire = c.gdk_wayland_display_get_wl_display(display) orelse {
            a.destroy(self);
            return null;
        };
        self.* = .{ .display = wire, .registry = c.wl_display_get_registry(wire).? };
        _ = c.wl_registry_add_listener(self.registry, &registry_listener, self);
        if (c.wl_display_roundtrip(wire) < 0 or self.shell == null) {
            destroy(self);
            return null;
        }
        c.g_object_set_data_full(cast(c.GObject, display), "desktop-layer-connection", self, &destroy);
        return self;
    }

    fn global(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self = cast(Connection, data);
        if (self.shell == null and std.mem.eql(u8, std.mem.span(interface), "zwlr_layer_shell_v1")) {
            self.shell = @ptrCast(c.wl_registry_bind(registry, name, &p.zwlr_layer_shell_v1_interface, @min(version, 4)));
            self.global_name = name;
        }
    }
    fn removed(data: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
        const self = cast(Connection, data);
        if (name == self.global_name) {
            if (self.shell) |shell| c.wl_proxy_destroy(shell);
            self.shell = null;
        }
    }
    const registry_listener: c.wl_registry_listener = .{ .global = &global, .global_remove = &removed };
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self = cast(Connection, data);
        if (self.shell) |shell| c.wl_proxy_destroy(shell);
        c.wl_registry_destroy(self.registry);
        a.destroy(self);
    }
};

const State = struct {
    window: *c.GtkWindow,
    connection: *Connection,
    role: ?*Proxy = null,
    monitor: ?*c.GdkMonitor = null,
    namespace: [:0]u8,
    layer: Layer = .top,
    keyboard: KeyboardMode = .none,
    anchors: [4]bool = @splat(false),
    margins: [4]i32 = @splat(0),
    zone: i32 = 0,
    auto_zone: bool = false,
    allocation: [2]u32 = .{ 1, 1 },
    sent_size: ?[2]u32 = null,
    configured_size: [2]u32 = .{ 0, 0 },
    configured: bool = false,
    closed: bool = false,
    close_idle: c.guint = 0,
    monitor_added: c.gulong = 0,
    monitor_removed: c.gulong = 0,
    display: *c.GdkDisplay,

    fn get(window: [*c]c.GtkWindow) *State {
        return cast(State, c.g_object_get_data(cast(c.GObject, window), state_key));
    }
    fn fromGdk(window: *c.GdkWindow) *State {
        return cast(State, c.g_object_get_data(cast(c.GObject, window), state_key));
    }
    fn widget(self: *State) *c.GtkWidget {
        return cast(c.GtkWidget, self.window);
    }
    fn invalidate(self: *State) void {
        if (c.gtk_widget_get_window(self.widget())) |window| c.gdk_window_invalidate_rect(window, null, 0);
    }
    fn stretched(self: *State, axis: usize) bool {
        return self.anchors[axis * 2] and self.anchors[axis * 2 + 1];
    }
    fn size(self: *State) void {
        const desired: [2]u32 = .{ if (self.stretched(0)) 0 else self.allocation[0], if (self.stretched(1)) 0 else self.allocation[1] };
        if (self.sent_size) |previous| if (std.meta.eql(previous, desired)) return;
        if (self.role) |role| {
            request(role, 0, .{ desired[0], desired[1] });
            self.sent_size = desired;
        }
    }
    fn hints(self: *State) void {
        const width: i32 = if (self.stretched(0) and self.configured_size[0] > 0) @intCast(self.configured_size[0]) else -1;
        const height: i32 = if (self.stretched(1) and self.configured_size[1] > 0) @intCast(self.configured_size[1]) else -1;
        var geometry: c.GdkGeometry = .{ .min_width = width, .max_width = width, .min_height = height, .max_height = height };
        c.gtk_window_set_geometry_hints(self.window, null, &geometry, c.GDK_HINT_MIN_SIZE | c.GDK_HINT_MAX_SIZE);
        self.size();
    }
    fn anchorBits(self: *State) u32 {
        var bits: u32 = 0;
        for (self.anchors, [_]u32{ 4, 8, 1, 2 }) |enabled, flag| if (enabled) {
            bits |= flag;
        };
        return bits;
    }
    fn updateZone(self: *State) void {
        if (!self.auto_zone) return;
        const horizontal = self.anchors[0] == self.anchors[1];
        const vertical = self.anchors[2] == self.anchors[3];
        var zone: i64 = -1;
        if (horizontal and !vertical) {
            zone = self.allocation[1];
            if (!self.anchors[2]) zone += self.margins[2];
            if (!self.anchors[3]) zone += self.margins[3];
        } else if (vertical and !horizontal) {
            zone = self.allocation[0];
            if (!self.anchors[0]) zone += self.margins[0];
            if (!self.anchors[1]) zone += self.margins[1];
        }
        if (zone >= 0 and zone <= std.math.maxInt(i32) and zone != self.zone) {
            self.zone = @intCast(zone);
            if (self.role) |role| request(role, 2, .{self.zone});
        }
    }
    fn sendMargins(self: *State) void {
        if (self.role) |role| request(role, 3, .{ self.margins[2], self.margins[1], self.margins[3], self.margins[0] });
    }
    fn remap(self: *State) void {
        if (self.role == null) return;
        c.gtk_widget_hide(self.widget());
        c.gtk_widget_show(self.widget());
    }
    fn realize(widget_: *c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
        const window = c.gtk_widget_get_window(widget_).?;
        const object = cast(c.GObject, window);
        c.g_object_set_data(object, state_key, data);
        c.g_object_set_data(object, "desktop-layer-map", @ptrCast(@constCast(&map)));
        c.g_object_set_data(object, "desktop-layer-unmap", @ptrCast(@constCast(&unmap)));
        c.g_object_set_data(object, "desktop-layer-popup", @ptrCast(@constCast(&popup)));
        c.gdk_wayland_window_set_use_custom_surface(window);
    }
    fn map(window: *c.GdkWindow) callconv(.c) c.gboolean {
        const self = fromGdk(window);
        const shell = self.connection.shell orelse return 0;
        const surface = c.gdk_wayland_window_get_wl_surface(window) orelse return 0;
        // GDK may have staged a background buffer before assigning the role.
        request(@ptrCast(surface), 1, .{ @as(?*anyopaque, null), @as(i32, 0), @as(i32, 0) });
        self.role = c.wl_proxy_marshal_flags(shell, 0, &p.zwlr_layer_surface_v1_interface, c.wl_proxy_get_version(shell), 0, @as(?*anyopaque, null), surface, if (self.monitor) |m| c.gdk_wayland_monitor_get_wl_output(m) else @as(?*c.wl_output, null), @backingInt(self.layer), self.namespace.ptr) orelse return 0;
        c.g_object_set_data(cast(c.GObject, window), "desktop-layer-surface", self.role);
        self.configured = false;
        self.closed = false;
        self.sent_size = null;
        self.configured_size = .{ 0, 0 };
        _ = c.wl_proxy_add_listener(self.role, @ptrCast(@constCast(&listener)), self);
        self.size();
        request(self.role.?, 1, .{self.anchorBits()});
        self.updateZone();
        request(self.role.?, 2, .{self.zone});
        self.sendMargins();
        request(self.role.?, 4, .{self.keyboardValue()});
        request(@ptrCast(surface), 6, .{}); // Initial commit has no buffer.
        if (c.wl_display_roundtrip(self.connection.display) < 0 or !self.configured or self.closed) {
            unmap(window);
            return 0;
        }
        return 1;
    }
    fn keyboardValue(self: *State) u32 {
        if (self.keyboard == .on_demand and c.wl_proxy_get_version(self.role.?) < 4) return 1;
        return @backingInt(self.keyboard);
    }
    fn unmap(window: *c.GdkWindow) callconv(.c) void {
        const self = fromGdk(window);
        if (self.role) |role| {
            _ = c.wl_proxy_marshal_flags(role, 7, null, c.wl_proxy_get_version(role), 1);
            self.role = null;
        }
        c.g_object_set_data(cast(c.GObject, window), "desktop-layer-surface", null);
        self.configured = false;
        self.sent_size = null;
    }
    fn popup(window: *c.GdkWindow, popup_: *Proxy) callconv(.c) void {
        if (fromGdk(window).role) |role| request(role, 5, .{popup_});
    }
    fn configure(data: ?*anyopaque, role: *Proxy, serial: u32, width: u32, height: u32) callconv(.c) void {
        const self = cast(State, data);
        request(role, 6, .{serial});
        if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) {
            self.closed = true;
            return;
        }
        self.configured = true;
        self.configured_size = .{ width, height };
        self.hints();
    }
    fn close(data: ?*anyopaque, _: *Proxy) callconv(.c) void {
        const self = cast(State, data);
        self.closed = true;
        // Avoid destroying a GTK widget inside the initial map callback.
        if (self.configured and self.close_idle == 0) self.close_idle = c.g_idle_add(&hideClosed, self);
    }
    fn hideClosed(data: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(State, data);
        self.close_idle = 0;
        if (self.closed) c.gtk_widget_hide(self.widget());
        return 0;
    }
    fn monitorChanged(display: *c.GdkDisplay, _: *c.GdkMonitor, data: ?*anyopaque) callconv(.c) void {
        const self = cast(State, data);
        if (self.monitor == null and (self.role != null or self.closed)) {
            c.gtk_widget_hide(self.widget());
            if (c.gdk_display_get_n_monitors(display) > 0) c.gtk_widget_show(self.widget());
        }
    }
    const Listener = extern struct {
        configure: *const fn (?*anyopaque, *Proxy, u32, u32, u32) callconv(.c) void = &configure,
        closed: *const fn (?*anyopaque, *Proxy) callconv(.c) void = &close,
    };
    const listener: Listener = .{};
    fn allocate(_: *c.GtkWidget, allocation: *c.GdkRectangle, data: ?*anyopaque) callconv(.c) void {
        const self = cast(State, data);
        const desired: [2]u32 = .{ @intCast(@max(1, allocation.width)), @intCast(@max(1, allocation.height)) };
        if (std.meta.eql(desired, self.allocation)) return;
        self.allocation = desired;
        self.size();
        self.updateZone();
        self.invalidate();
    }
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self = cast(State, data);
        if (self.close_idle != 0) _ = c.g_source_remove(self.close_idle);
        c.g_signal_handler_disconnect(self.display, self.monitor_added);
        c.g_signal_handler_disconnect(self.display, self.monitor_removed);
        if (self.monitor) |monitor| c.g_object_unref(monitor);
        a.free(self.namespace);
        a.destroy(self);
    }
};

pub fn init_for_window(window: [*c]c.GtkWindow) void {
    if (c.g_object_get_data(cast(c.GObject, window), state_key) != null) return;
    const self = a.create(State) catch @panic("out of memory");
    const display = c.gdk_display_get_default().?;
    self.* = .{ .window = window, .display = display, .connection = Connection.get(display) orelse @panic("Compositor does not support layer shell"), .namespace = a.dupeSentinel(u8, "desktop-zig", 0) catch @panic("out of memory") };
    c.g_object_set_data_full(cast(c.GObject, window), state_key, self, &State.destroy);
    c.gtk_window_set_decorated(window, 0);
    _ = c.g_signal_connect_data(window, "realize", @ptrCast(&State.realize), self, null, 0);
    _ = c.g_signal_connect_data(window, "size-allocate", @ptrCast(&State.allocate), self, null, 0);
    self.monitor_added = c.g_signal_connect_data(display, "monitor-added", @ptrCast(&State.monitorChanged), self, null, 0);
    self.monitor_removed = c.g_signal_connect_data(display, "monitor-removed", @ptrCast(&State.monitorChanged), self, null, 0);
}
pub fn is_supported() c.gboolean {
    const display = c.gdk_display_get_default() orelse return 0;
    if (c.g_type_check_instance_is_a(@ptrCast(display), c.gdk_wayland_display_get_type()) == 0) return 0;
    return @intFromBool(Connection.get(display) != null);
}
pub fn set_namespace(window: [*c]c.GtkWindow, namespace: [*c]const u8) void {
    const self = State.get(window);
    if (std.mem.eql(u8, self.namespace, std.mem.span(namespace))) return;
    const copy = a.dupeSentinel(u8, std.mem.span(namespace), 0) catch @panic("out of memory");
    a.free(self.namespace);
    self.namespace = copy;
    self.remap();
}
pub fn set_layer(window: [*c]c.GtkWindow, layer: Layer) void {
    const self = State.get(window);
    self.layer = layer;
    if (self.role) |role| {
        if (c.wl_proxy_get_version(role) >= 2) request(role, 8, .{@backingInt(layer)}) else self.remap();
        self.invalidate();
    }
}
pub fn set_monitor(window: [*c]c.GtkWindow, monitor: ?*c.GdkMonitor) void {
    const self = State.get(window);
    if (self.monitor == monitor) return;
    if (monitor) |m| _ = c.g_object_ref(m);
    if (self.monitor) |m| c.g_object_unref(m);
    self.monitor = monitor;
    self.remap();
}
pub fn set_anchor(window: [*c]c.GtkWindow, edge: Edge, enabled: c.gboolean) void {
    const self = State.get(window);
    self.anchors[@backingInt(edge)] = enabled != 0;
    if (self.role) |role| request(role, 1, .{self.anchorBits()});
    self.hints();
    self.updateZone();
    self.invalidate();
}
pub fn set_margin(window: [*c]c.GtkWindow, edge: Edge, margin: i32) void {
    const self = State.get(window);
    self.margins[@backingInt(edge)] = margin;
    self.sendMargins();
    self.updateZone();
    self.invalidate();
}
pub fn set_exclusive_zone(window: [*c]c.GtkWindow, zone: i32) void {
    const self = State.get(window);
    self.auto_zone = false;
    self.zone = zone;
    if (self.role) |role| request(role, 2, .{zone});
    self.invalidate();
}
pub fn auto_exclusive_zone_enable(window: [*c]c.GtkWindow) void {
    const self = State.get(window);
    self.auto_zone = true;
    self.updateZone();
    self.invalidate();
}
pub fn set_keyboard_mode(window: [*c]c.GtkWindow, mode: KeyboardMode) void {
    const self = State.get(window);
    self.keyboard = mode;
    if (self.role) |role| request(role, 4, .{self.keyboardValue()});
    self.invalidate();
}

test "native layer roles configure, reserve space, attach GTK popups, and remap" {
    try std.testing.expect(c.gtk_init_check(null, null) != 0);
    try std.testing.expect(is_supported() != 0);
    const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL).?;
    // Keep the GObject data alive after destroy to verify the role was unmapped.
    _ = c.g_object_ref(window);
    defer c.g_object_unref(window);
    var destroyed = false;
    defer if (!destroyed) c.gtk_widget_destroy(window);
    const gtk_window = cast(c.GtkWindow, window);
    init_for_window(gtk_window);
    set_namespace(gtk_window, "desktop-layer-test");
    set_layer(gtk_window, .top);
    set_anchor(gtk_window, .top, 1);
    set_anchor(gtk_window, .left, 1);
    set_anchor(gtk_window, .right, 1);
    auto_exclusive_zone_enable(gtk_window);
    const button = c.gtk_button_new_with_label("Layer popup").?;
    c.gtk_widget_set_size_request(button, 160, 32);
    c.gtk_container_add(cast(c.GtkContainer, window), button);
    c.gtk_widget_show_all(window);
    const self = State.get(gtk_window);
    try std.testing.expect(self.role != null and self.configured);
    try std.testing.expect(self.configured_size[0] >= 160);
    try std.testing.expect(self.zone >= 32);
    const zone = self.zone;
    set_margin(gtk_window, .bottom, 7);
    try std.testing.expectEqual(zone + 7, self.zone);

    const Probe = struct {
        var attached: usize = 0;
        fn attach(gdk: *c.GdkWindow, popup_: *Proxy) callconv(.c) void {
            State.popup(gdk, popup_);
            attached += 1;
        }
    };
    Probe.attached = 0;
    c.g_object_set_data(cast(c.GObject, c.gtk_widget_get_window(window)), "desktop-layer-popup", @ptrCast(@constCast(&Probe.attach)));
    const popover = c.gtk_popover_new(button).?;
    _ = c.g_object_ref_sink(popover);
    defer c.g_object_unref(popover);
    defer c.gtk_widget_destroy(popover);
    c.gtk_popover_set_modal(cast(c.GtkPopover, popover), 0);
    c.gtk_container_add(cast(c.GtkContainer, popover), c.gtk_label_new("Native layer popup"));
    c.gtk_widget_show_all(popover);
    c.gtk_popover_popup(cast(c.GtkPopover, popover));
    for (0..5) |_| {
        while (c.gtk_events_pending() != 0) _ = c.gtk_main_iteration();
        _ = @import("desktop-libc.zig").poll(null, 0, 10);
    }
    // GtkPopover uses a subsurface. A menu-style GtkWindow additionally checks
    // the xdg_popup attachment hook used by menus, tooltips and combo boxes.
    const popup_window = c.gtk_window_new(c.GTK_WINDOW_POPUP).?;
    defer c.gtk_widget_destroy(popup_window);
    c.gtk_window_set_transient_for(cast(c.GtkWindow, popup_window), gtk_window);
    c.gtk_window_set_type_hint(cast(c.GtkWindow, popup_window), c.GDK_WINDOW_TYPE_HINT_POPUP_MENU);
    c.gtk_container_add(cast(c.GtkContainer, popup_window), c.gtk_label_new("Popup role"));
    c.gtk_widget_show_all(popup_window);
    try std.testing.expect(Probe.attached > 0);
    try std.testing.expect(c.wl_display_roundtrip(self.connection.display) >= 0);
    c.gtk_widget_hide(popup_window);
    c.gtk_widget_hide(popover);
    c.gtk_widget_hide(window);
    try std.testing.expect(self.role == null);
    c.gtk_widget_show(window);
    try std.testing.expect(self.role != null and self.configured);
    set_namespace(gtk_window, "desktop-layer-remapped");
    try std.testing.expect(self.role != null and self.configured);
    set_monitor(gtk_window, c.gdk_display_get_monitor(self.display, 0));
    try std.testing.expect(self.role != null and self.configured);
    try std.testing.expect(c.wl_display_roundtrip(self.connection.display) >= 0);
    c.gtk_widget_destroy(window);
    destroyed = true;
    try std.testing.expect(self.role == null);
}
