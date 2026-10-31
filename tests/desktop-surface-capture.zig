//! Read compositor output pixels independently of the native rendering client.
const std = @import("std");
const sc = @import("../desktop-screenshot.zig");
const libc = @import("../desktop-libc.zig");
const c = sc.c;
pub const Frame = struct {
    bytes: []u8,
    width: u32,
    height: u32,
    stride: u32,
    pub fn deinit(self: Frame) void {
        std.testing.allocator.free(self.bytes);
    }
    pub fn pixel(self: Frame, x: u32, y: u32) u32 {
        const offset = @as(usize, y) * self.stride + @as(usize, x) * 4;
        return std.mem.readInt(u32, self.bytes[offset..][0..4], @import("builtin").cpu.arch.endian()) & 0xffffff;
    }
};
pub fn capture() !Frame {
    var client: sc.WaylandClient = undefined;
    try client.init(std.testing.allocator);
    defer client.deinit();
    var frame: sc.FrameCapture = .{
        .shm = client.shm.?,
        .frame = sc.protocols.zwlr_screencopy_manager_v1_capture_output(client.screencopy_mgr.?, 0, client.outputs.items[0].wl_out).?,
    };
    defer sc.protocols.zwlr_screencopy_frame_v1_destroy(frame.frame);
    defer {
        if (frame.buffer) |buffer| c.wl_buffer_destroy(buffer);
        if (frame.memory) |memory| _ = libc.munmap(memory, frame.length);
    }
    _ = sc.protocols.zwlr_screencopy_frame_v1_add_listener(frame.frame, &sc.FrameCapture.listener, &frame);
    while (!frame.done and !frame.failed) try std.testing.expect(c.wl_display_dispatch(client.display) >= 0);
    try std.testing.expect(!frame.failed and frame.memory != null);
    return .{ .bytes = try std.testing.allocator.dupe(u8, frame.memory.?[0..frame.length]), .width = frame.width, .height = frame.height, .stride = frame.stride };
}
pub fn pump() void {
    for (0..20) |_| {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        _ = libc.poll(null, 0, 10);
    }
}
