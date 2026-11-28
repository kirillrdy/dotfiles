//! Screen video producer: a native PipeWire node that drives its own graph,
//! starting a cycle for each captured frame. Capture and lifecycle run on the
//! broker's main loop; frames are copied into PipeWire buffers on the node thread.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const spa = @import("desktop-spa.zig");
const Pod = @import("desktop-audio-pod.zig");
const pipewire = @import("desktop-pipewire-node.zig");
const Capture = @import("desktop-portal-capture.zig").Capture;
fn cast(comptime T: type, ptr: anytype) *T { return @ptrCast(@alignCast(ptr)); }
const Image = @import("desktop-image.zig").Image;
pub const Stream = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    name: [:0]u8,
    cursor: bool,
    capture: ?*Capture = null,
    node: ?*pipewire.Node = null,
    timer: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    failed: bool = false,
    announced: bool = false,
    ticks: u32 = 0,
    callback: *const fn (?*anyopaque, ?u32) void,
    data: ?*anyopaque,
    /// The latest frame, shared with the node thread.
    mutex: util.Mutex = .{},
    image: ?Image = null,
    /// Set on the node thread when a frame does not fit its buffer.
    broken: std.atomic.Value(bool) = .init(false),

    pub fn create(allocator: std.mem.Allocator, io: std.Io, name: []const u8, cursor: bool, callback: *const fn (?*anyopaque, ?u32) void, data: ?*anyopaque) !*Stream {
        const self = try allocator.create(Stream);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .name = try allocator.dupeSentinel(u8, name, 0), .cursor = cursor, .callback = callback, .data = data };
        self.timer = mainloop.timeout(io, 10, self, tick);
        return self;
    }
    pub fn destroy(self: *Stream) void {
        if (self.timer != 0) _ = mainloop.remove(self.io, self.timer);
        if (self.capture) |capture| capture.destroy();
        if (self.node) |node| node.destroy();
        if (self.image) |image| image.deinit(self.allocator);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
    fn captured(data: ?*anyopaque, image: ?Image) void {
        const self = cast(Stream, data);
        const value = image orelse {
            self.failed = true;
            return;
        };
        if (self.node != null and (self.width != value.width or self.height != value.height)) {
            value.deinit(self.allocator);
            self.failed = true;
            return;
        }
        self.mutex.lock(self.io);
        const old = self.image;
        self.image = value;
        self.mutex.unlock(self.io);
        if (old) |previous| previous.deinit(self.allocator);
        if (self.node == null) {
            self.width = value.width;
            self.height = value.height;
            self.start() catch {
                self.failed = true;
            };
        }
    }
    fn start(self: *Stream) !void {
        var bytes: [512]u8 align(8) = undefined;
        var format = try Pod.Builder.init(&bytes, spa.SPA_TYPE_OBJECT_Format, spa.SPA_PARAM_EnumFormat);
        try format.identifier(spa.SPA_FORMAT_mediaType, spa.SPA_MEDIA_TYPE_video);
        try format.identifier(spa.SPA_FORMAT_mediaSubtype, spa.SPA_MEDIA_SUBTYPE_raw);
        try format.identifier(spa.SPA_FORMAT_VIDEO_format, if (@import("builtin").cpu.arch.endian() == .little) spa.SPA_VIDEO_FORMAT_BGRx else spa.SPA_VIDEO_FORMAT_xRGB);
        try format.pair(spa.SPA_FORMAT_VIDEO_size, spa.SPA_TYPE_Rectangle, self.width, self.height);
        try format.pair(spa.SPA_FORMAT_VIDEO_framerate, spa.SPA_TYPE_Fraction, 30, 1);
        const ports = [_]pipewire.PortSpec{.{ .enum_format = format.view().bytes, .properties = &.{.{ "port.name", "output" }} }};
        self.node = try pipewire.Node.create(self.allocator, .{ .properties = &.{
            .{ "media.type", "Video" },
            .{ "media.category", "Capture" },
            .{ "media.role", "Screen" },
            .{ "media.class", "Video/Source" },
            .{ "node.name", "desktop-screen" },
            .{ "node.description", self.name },
            .{ "node.driver", "true" },
        }, .ports = &ports }, .{ .context = self, .format = &buffers, .process = &process });
    }
    fn tick(self: *Stream) bool {
        self.ticks +%= 1;
        if (self.capture == null and self.ticks >= 15) {
            self.capture = Capture.create(self.allocator, self.io, self.name, self.cursor, &captured, self) catch null;
            if (self.capture == null) self.failed = true;
        }
        const state: pipewire.State = if (self.node) |node| node.state.load(.acquire) else .connecting;
        if (state == .failed or state == .finished or self.broken.load(.acquire)) self.failed = true;
        if (!self.announced and self.ticks > 1000) self.failed = true;
        if (self.failed) {
            self.timer = 0;
            self.callback(self.data, null);
            return false;
        }
        if (!self.announced and self.node != null) {
            const node = self.node.?.global_id.load(.acquire);
            if (node != spa.PW_ID_ANY) {
                self.announced = true;
                self.callback(self.data, node);
                // A successful callback retains this stream in the session.
            }
        }
        if (self.announced and self.ticks % (if (state == .streaming) @as(u32, 3) else @as(u32, 100)) == 0) {
            if (self.capture.?.source == 0) self.capture.?.next(self.name, self.cursor) catch {
                self.failed = true;
                return true;
            };
            if (state == .streaming) self.node.?.trigger();
        }
        return true;
    }
    fn buffers(context: *anyopaque, _: u32, _: []const u8, out: []align(8) u8) ?[]const u8 {
        const self: *Stream = @ptrCast(@alignCast(context));
        var builder = Pod.Builder.init(out, spa.SPA_TYPE_OBJECT_ParamBuffers, spa.SPA_PARAM_Buffers) catch return null;
        builder.integer(spa.SPA_PARAM_BUFFERS_buffers, 4) catch return null;
        builder.integer(spa.SPA_PARAM_BUFFERS_blocks, 1) catch return null;
        builder.integer(spa.SPA_PARAM_BUFFERS_size, @intCast(self.width * self.height * 4)) catch return null;
        builder.integer(spa.SPA_PARAM_BUFFERS_stride, @intCast(self.width * 4)) catch return null;
        builder.flags(spa.SPA_PARAM_BUFFERS_dataType, 1 << spa.SPA_DATA_MemFd) catch return null;
        return builder.view().bytes;
    }
    /// Copies the latest frame into the cycle's buffer.
    fn process(context: *anyopaque, cycle: *pipewire.Cycle) void {
        const self: *Stream = @ptrCast(@alignCast(context));
        const buffer = cycle.buffers[0] orelse return;
        self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const image = self.image orelse return;
        const row = self.width * 4;
        const size = row * self.height;
        if (buffer.data.len < size or image.width != self.width or image.height != self.height) {
            self.broken.store(true, .release);
            return;
        }
        for (0..self.height) |y| @memcpy(buffer.data[y * row ..][0..row], image.pixels[y * image.stride ..][0..row]);
        buffer.chunk.* = .{ .offset = 0, .size = size, .stride = @intCast(row), .flags = 0 };
    }
};
