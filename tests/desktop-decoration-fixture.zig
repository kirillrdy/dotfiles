//! Exercise Chrome's decoration ordering without needing a browser or a GPU.
const std = @import("std");
const c = @import("decoration-client");

var compositor: ?*c.wl_compositor = null;
var shell: ?*c.xdg_wm_base = null;
var manager: ?*c.zxdg_decoration_manager_v1 = null;
var configures: usize = 0;
var decoration_configures: usize = 0;

fn ping(_: ?*anyopaque, base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    c.xdg_wm_base_pong(base, serial);
}
const shell_listener = c.xdg_wm_base_listener{ .ping = ping };

fn global(_: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, _: u32) callconv(.c) void {
    const iface = std.mem.span(interface);
    if (std.mem.eql(u8, iface, "wl_compositor"))
        compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 1));
    if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        shell = @ptrCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, 1));
        std.debug.assert(c.xdg_wm_base_add_listener(shell, &shell_listener, null) == 0);
    }
    if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1"))
        manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zxdg_decoration_manager_v1_interface, 1));
}
fn removed(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}
const registry_listener = c.wl_registry_listener{ .global = global, .global_remove = removed };

fn configure(_: ?*anyopaque, surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    c.xdg_surface_ack_configure(surface, serial);
    configures += 1;
}
const surface_listener = c.xdg_surface_listener{ .configure = configure };

fn decorated(_: ?*anyopaque, _: ?*c.zxdg_toplevel_decoration_v1, mode: u32) callconv(.c) void {
    std.debug.assert(mode == c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
    decoration_configures += 1;
}
const decoration_listener = c.zxdg_toplevel_decoration_v1_listener{ .configure = decorated };

fn roundtrip(display: *c.wl_display) !void {
    if (c.wl_display_roundtrip(display) < 0) return error.Disconnected;
}

fn check(display: *c.wl_display, early: bool, abandon: bool) !void {
    const surface = c.wl_compositor_create_surface(compositor) orelse return error.Surface;
    defer c.wl_surface_destroy(surface);
    const xdg = c.xdg_wm_base_get_xdg_surface(shell, surface) orelse return error.XdgSurface;
    defer c.xdg_surface_destroy(xdg);
    if (c.xdg_surface_add_listener(xdg, &surface_listener, null) != 0) return error.Listener;
    const toplevel = c.xdg_surface_get_toplevel(xdg) orelse return error.Toplevel;
    defer c.xdg_toplevel_destroy(toplevel);
    var before = configures;
    const before_decoration = decoration_configures;
    if (!early) {
        c.wl_surface_commit(surface);
        while (configures == before) try roundtrip(display);
        before = configures;
    }
    const decoration = c.zxdg_decoration_manager_v1_get_toplevel_decoration(manager, toplevel) orelse return error.Decoration;
    defer c.zxdg_toplevel_decoration_v1_destroy(decoration);
    if (c.zxdg_toplevel_decoration_v1_add_listener(decoration, &decoration_listener, null) != 0) return error.Listener;
    c.zxdg_toplevel_decoration_v1_set_mode(decoration, c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    try roundtrip(display);
    if (early and configures != before) return error.PrematureConfigure;
    c.zxdg_toplevel_decoration_v1_unset_mode(decoration);
    try roundtrip(display);
    if (!abandon) {
        c.wl_surface_commit(surface);
        while (configures == before or decoration_configures == before_decoration) try roundtrip(display);
        c.zxdg_toplevel_decoration_v1_set_mode(decoration, c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
        try roundtrip(display);
        try roundtrip(display);
    }
}

pub fn main() !void {
    const display = c.wl_display_connect(null) orelse return error.Display;
    defer c.wl_display_disconnect(display);
    const registry = c.wl_display_get_registry(display) orelse return error.Registry;
    defer c.wl_registry_destroy(registry);
    if (c.wl_registry_add_listener(registry, &registry_listener, null) != 0) return error.Listener;
    try roundtrip(display);
    if (compositor == null or shell == null or manager == null) return error.MissingGlobals;
    defer c.wl_compositor_destroy(compositor);
    defer c.xdg_wm_base_destroy(shell);
    defer c.zxdg_decoration_manager_v1_destroy(manager);
    for ([_][2]bool{ .{ true, false }, .{ false, false }, .{ true, true }, .{ true, false } }) |scenario| {
        try check(display, scenario[0], scenario[1]);
        try roundtrip(display);
    }
    std.debug.print("early/late decoration, mode requests and destruction PASS\n", .{});
}
