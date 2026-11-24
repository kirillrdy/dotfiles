//! Exercise Chrome's decoration ordering without needing a browser or a GPU.
const std = @import("std");
const wayland = @import("desktop").wayland;
const wire = wayland.wire;
const wl = wayland.protocol;

const State = struct {
    compositor: ?wl.wl_compositor = null,
    shell: ?wl.xdg_wm_base = null,
    manager: ?wl.zxdg_decoration_manager_v1 = null,
    configures: usize = 0,
    decoration_configures: usize = 0,

    fn registryEvent(self: *State, registry: wl.wl_registry, event: wl.wl_registry.Event) void {
        switch (event) {
            .global => |g| {
                if (std.mem.eql(u8, g.interface, "wl_compositor"))
                    self.compositor = registry.bind(g.name, wl.wl_compositor, 1);
                if (std.mem.eql(u8, g.interface, "xdg_wm_base")) {
                    const base = registry.bind(g.name, wl.xdg_wm_base, 1);
                    self.shell = base;
                    base.listen(State, self, shellEvent);
                }
                if (std.mem.eql(u8, g.interface, "zxdg_decoration_manager_v1"))
                    self.manager = registry.bind(g.name, wl.zxdg_decoration_manager_v1, 1);
            },
            .global_remove => {},
        }
    }

    fn shellEvent(_: *State, base: wl.xdg_wm_base, event: wl.xdg_wm_base.Event) void {
        switch (event) {
            .ping => |p| base.pong(p.serial),
        }
    }

    fn surfaceEvent(self: *State, surface: wl.xdg_surface, event: wl.xdg_surface.Event) void {
        switch (event) {
            .configure => |c| {
                surface.ack_configure(c.serial);
                self.configures += 1;
            },
        }
    }

    fn decorationEvent(self: *State, _: wl.zxdg_toplevel_decoration_v1, event: wl.zxdg_toplevel_decoration_v1.Event) void {
        switch (event) {
            .configure => |c| {
                std.debug.assert(c.mode == wl.zxdg_toplevel_decoration_v1.Mode.client_side);
                self.decoration_configures += 1;
            },
        }
    }

    fn check(self: *State, connection: *wire.Connection, early: bool, abandon: bool) !void {
        const surface = self.compositor.?.create_surface();
        defer surface.destroy();
        const xdg = self.shell.?.get_xdg_surface(surface);
        defer xdg.destroy();
        xdg.listen(State, self, surfaceEvent);
        const toplevel = xdg.get_toplevel();
        defer toplevel.destroy();
        var before = self.configures;
        const before_decoration = self.decoration_configures;
        if (!early) {
            surface.commit();
            while (self.configures == before) try connection.roundtrip();
            before = self.configures;
        }
        const decoration = self.manager.?.get_toplevel_decoration(toplevel);
        defer decoration.destroy();
        decoration.listen(State, self, decorationEvent);
        decoration.set_mode(wl.zxdg_toplevel_decoration_v1.Mode.server_side);
        try connection.roundtrip();
        if (early and self.configures != before) return error.PrematureConfigure;
        decoration.unset_mode();
        try connection.roundtrip();
        if (!abandon) {
            surface.commit();
            while (self.configures == before or self.decoration_configures == before_decoration) try connection.roundtrip();
            decoration.set_mode(wl.zxdg_toplevel_decoration_v1.Mode.server_side);
            try connection.roundtrip();
            try connection.roundtrip();
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const connection = try wire.Connection.connect(init.gpa);
    defer connection.deinit();
    const display: wl.wl_display = .{ .proxy = connection.display() };
    var state: State = .{};
    const registry = display.get_registry();
    defer registry.destroy();
    registry.listen(State, &state, State.registryEvent);
    try connection.roundtrip();
    if (state.compositor == null or state.shell == null or state.manager == null) return error.MissingGlobals;
    defer state.compositor.?.destroy();
    defer state.shell.?.destroy();
    defer state.manager.?.destroy();
    for ([_][2]bool{ .{ true, false }, .{ false, false }, .{ true, true }, .{ true, false } }) |scenario| {
        try state.check(connection, scenario[0], scenario[1]);
        try connection.roundtrip();
    }
    std.debug.print("early/late decoration, mode requests and destruction PASS\n", .{});
}
