//! Native Wayland windows for private compositor tests.
const std = @import("std");
const desktop = @import("desktop");
const mainloop = @import("desktop").mainloop;
const util = @import("desktop").util;
const wire = desktop.window.wire;
const cast = util.cast;

const State = struct {
    io: std.Io,
    title: [:0]const u8,
    surface: ?*wire.Surface = null,
    frame: u32 = 0,
    closed: bool = false,

    fn output(_: ?*anyopaque, _: *wire.Output) void {}
    fn paint(ptr: ?*anyopaque, pixels: wire.Pixels) void {
        const self = cast(State, ptr);
        @memset(pixels.pixels, 0xff245b98 +% self.frame);
    }
    fn close(ptr: ?*anyopaque) void {
        cast(State, ptr).closed = true;
    }
    fn focus(ptr: ?*anyopaque, _: *wire.Surface, active: bool) void {
        const self = cast(State, ptr);
        if (active) @import("desktop").util.printOut("{d} {s}\n", .{ std.Io.Clock.awake.now(self.io).toMicroseconds(), self.title });
    }
    fn animate(self: *State) bool {
        self.frame +%= 0x00030507;
        if (self.surface) |surface| surface.redraw();
        return true;
    }
};

pub fn main(init: std.process.Init) !void {
    const a = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.InvalidArguments;
    var state: State = .{ .io = init.io, .title = args[2] };
    const client = try wire.Client.createInteractive(init.gpa, init.io, .{ .added = &State.output, .removed = &State.output }, &state);
    defer client.destroy();
    if (client.outputs.items.len == 0) return error.NoOutputs;
    const surface = try wire.Surface.createPixels(client.outputs.items[0], .{ .namespace = args[1], .title = args[2], .role = .toplevel, .width = 640, .height = 420, .interactive = true, .cursor = .arrow }, &State.paint, &state);
    state.surface = surface;
    surface.input = .{ .focus = &State.focus };
    surface.close = &State.close;
    const timer = if (std.c.getenv("DESKTOP_FIXTURE_ANIMATE") != null) mainloop.timeout(init.io, 100, &state, State.animate) else 0;
    defer if (timer != 0) {
        _ = mainloop.remove(init.io, timer);
    };
    try client.start();
    try surface.show();
    while (!state.closed) _ = mainloop.iteration(init.io, true);
}
