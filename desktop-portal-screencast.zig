//! PipeWire video producer. All callbacks run on the broker's GLib thread.
const std = @import("std");
const c = @import("gtk");
const p = @import("pipewire");
const Pod = @import("audio-pod");
const Capture = @import("desktop-portal-capture.zig").Capture;
const cast = c.__zig.cast;
fn control(loop: *p.pw_loop) struct { methods: *const p.spa_loop_control_methods, data: ?*anyopaque } {
    const iface = cast(p.spa_interface, loop.*.control);
    return .{ .methods = @ptrCast(@alignCast(iface.cb.funcs)), .data = iface.cb.data };
}
var initialized = false;
pub const Stream = struct {
    allocator: std.mem.Allocator,
    name: [:0]u8,
    cursor: bool,
    capture: ?*Capture = null,
    surface: ?*c.cairo_surface_t = null,
    loop: ?*p.pw_loop = null,
    stream: ?*p.pw_stream = null,
    timer: c.guint = 0,
    width: u32 = 0,
    height: u32 = 0,
    node: u32 = p.PW_ID_ANY,
    state: p.pw_stream_state = p.PW_STREAM_STATE_UNCONNECTED,
    failed: bool = false,
    announced: bool = false,
    ticks: u32 = 0,
    callback: *const fn (?*anyopaque, ?u32) void,
    data: ?*anyopaque,

    pub fn create(allocator: std.mem.Allocator, name: []const u8, cursor: bool, callback: *const fn (?*anyopaque, ?u32) void, data: ?*anyopaque) !*Stream {
        const self = try allocator.create(Stream);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .name = try allocator.dupeSentinel(u8, name, 0), .cursor = cursor, .callback = callback, .data = data };
        self.timer = c.g_timeout_add(10, &tick, self);
        return self;
    }
    pub fn destroy(self: *Stream) void {
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        if (self.capture) |capture| capture.destroy();
        if (self.stream) |stream| p.pw_stream_destroy(stream);
        if (self.loop) |loop| {
            const ctl = control(loop);
            ctl.methods.leave.?(ctl.data);
            p.pw_loop_destroy(loop);
        }
        if (self.surface) |surface| c.cairo_surface_destroy(surface);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
    fn captured(data: ?*anyopaque, surface: ?*c.cairo_surface_t) void {
        const self = cast(Stream, data);
        if (self.surface) |old| c.cairo_surface_destroy(old);
        self.surface = if (surface) |value| c.cairo_surface_reference(value) else null;
        if (self.surface) |value| {
            const width: u32 = @intCast(c.cairo_image_surface_get_width(value));
            const height: u32 = @intCast(c.cairo_image_surface_get_height(value));
            if (self.stream == null) {
                self.width = width;
                self.height = height;
                self.start() catch {
                    self.failed = true;
                };
            } else if (self.width != width or self.height != height) self.failed = true;
        } else self.failed = true;
    }
    fn start(self: *Stream) !void {
        if (!initialized) {
            p.pw_init(null, null);
            initialized = true;
        }
        const loop = p.pw_loop_new(null) orelse return error.PipeWireUnavailable;
        self.loop = loop;
        const ctl = control(loop);
        ctl.methods.enter.?(ctl.data);
        const properties = p.pw_properties_new(@as([*:0]const u8, "media.type"), @as([*:0]const u8, "Video"), @as([*:0]const u8, "media.category"), @as([*:0]const u8, "Capture"), @as([*:0]const u8, "media.role"), @as([*:0]const u8, "Screen"), @as([*:0]const u8, "media.class"), @as([*:0]const u8, "Video/Source"), @as([*:0]const u8, "node.name"), @as([*:0]const u8, "desktop-screen"), @as([*:0]const u8, "node.description"), self.name.ptr, @as(?*anyopaque, null)) orelse return error.PipeWireUnavailable;
        self.stream = p.pw_stream_new_simple(loop, "Desktop screen sharing", properties, &events, self) orelse return error.PipeWireUnavailable;
        var bytes: [512]u8 align(8) = undefined;
        var format = try Pod.Builder.init(&bytes, p.SPA_TYPE_OBJECT_Format, p.SPA_PARAM_EnumFormat);
        try format.identifier(p.SPA_FORMAT_mediaType, p.SPA_MEDIA_TYPE_video);
        try format.identifier(p.SPA_FORMAT_mediaSubtype, p.SPA_MEDIA_SUBTYPE_raw);
        try format.identifier(p.SPA_FORMAT_VIDEO_format, if (@import("builtin").cpu.arch.endian() == .little) p.SPA_VIDEO_FORMAT_BGRx else p.SPA_VIDEO_FORMAT_xRGB);
        try format.pair(p.SPA_FORMAT_VIDEO_size, p.SPA_TYPE_Rectangle, self.width, self.height);
        try format.pair(p.SPA_FORMAT_VIDEO_framerate, p.SPA_TYPE_Fraction, 30, 1);
        var params = [_][*c]const p.spa_pod{@ptrCast(&bytes)};
        if (p.pw_stream_connect(self.stream, p.PW_DIRECTION_OUTPUT, p.PW_ID_ANY, p.PW_STREAM_FLAG_DRIVER | p.PW_STREAM_FLAG_MAP_BUFFERS, &params, params.len) < 0) return error.StreamConnectFailed;
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Stream, data);
        self.ticks +%= 1;
        if (self.capture == null and self.ticks >= 15) {
            self.capture = Capture.create(self.allocator, self.name, self.cursor, &captured, self) catch null;
            if (self.capture == null) self.failed = true;
        }
        if (self.loop) |loop| {
            const ctl = control(loop);
            if (ctl.methods.iterate.?(ctl.data, 0) < 0) self.failed = true;
        }
        if (!self.announced and self.ticks > 1000) self.failed = true;
        if (self.failed) {
            self.timer = 0;
            self.callback(self.data, null);
            return 0;
        }
        if (!self.announced and self.stream != null and self.state >= p.PW_STREAM_STATE_PAUSED) {
            const node = p.pw_stream_get_node_id(self.stream);
            if (node != p.PW_ID_ANY) {
                self.node = node;
                self.announced = true;
                self.callback(self.data, node);
                // A successful callback retains this stream in the session.
            }
        }
        if (self.announced and self.ticks % (if (self.state == p.PW_STREAM_STATE_STREAMING) @as(u32, 3) else @as(u32, 100)) == 0) {
            if (self.capture.?.source == 0) self.capture.?.next(self.name, self.cursor) catch {
                self.failed = true;
                return 1;
            };
            if (self.state == p.PW_STREAM_STATE_STREAMING) _ = p.pw_stream_trigger_process(self.stream);
        }
        return 1;
    }
    fn stateChanged(data: ?*anyopaque, _: p.pw_stream_state, state: p.pw_stream_state, _: [*c]const u8) callconv(.c) void {
        const self = cast(Stream, data);
        self.state = state;
        if (state == p.PW_STREAM_STATE_ERROR or (self.announced and state == p.PW_STREAM_STATE_UNCONNECTED)) self.failed = true;
    }
    fn parameter(data: ?*anyopaque, id: u32, param: [*c]const p.spa_pod) callconv(.c) void {
        const self = cast(Stream, data);
        if (id != p.SPA_PARAM_Format or param == null) return;
        var bytes: [256]u8 align(8) = undefined;
        var buffers = Pod.Builder.init(&bytes, p.SPA_TYPE_OBJECT_ParamBuffers, p.SPA_PARAM_Buffers) catch unreachable;
        buffers.integer(p.SPA_PARAM_BUFFERS_buffers, 4) catch unreachable;
        buffers.integer(p.SPA_PARAM_BUFFERS_blocks, 1) catch unreachable;
        buffers.integer(p.SPA_PARAM_BUFFERS_size, @intCast(self.width * self.height * 4)) catch unreachable;
        buffers.integer(p.SPA_PARAM_BUFFERS_stride, @intCast(self.width * 4)) catch unreachable;
        buffers.integer(p.SPA_PARAM_BUFFERS_dataType, 1 << p.SPA_DATA_MemFd) catch unreachable;
        var params = [_][*c]const p.spa_pod{@ptrCast(&bytes)};
        if (p.pw_stream_update_params(self.stream, &params, params.len) < 0) self.failed = true;
    }
    fn process(data: ?*anyopaque) callconv(.c) void {
        const self = cast(Stream, data);
        const buffer = p.pw_stream_dequeue_buffer(self.stream) orelse return;
        defer _ = p.pw_stream_queue_buffer(self.stream, buffer);
        const raw = buffer.*.buffer;
        if (raw == null or raw.*.n_datas == 0) return;
        const dest = &raw.*.datas[0];
        if (dest.chunk == null) return;
        dest.chunk.*.offset = 0;
        dest.chunk.*.size = 0;
        const surface = self.surface orelse return;
        const size = self.width * self.height * 4;
        if (dest.data == null or dest.maxsize < size) {
            self.failed = true;
            return;
        }
        const src: [*]const u8 = c.cairo_image_surface_get_data(surface);
        const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
        const pixels: [*]u8 = @ptrCast(dest.data);
        for (0..self.height) |y| @memcpy(pixels[y * self.width * 4 ..][0 .. self.width * 4], src[y * stride ..][0 .. self.width * 4]);
        dest.chunk.*.size = size;
        dest.chunk.*.stride = @intCast(self.width * 4);
        buffer.*.size = 1;
    }
    const events: p.pw_stream_events = .{ .version = p.PW_VERSION_STREAM_EVENTS, .state_changed = &stateChanged, .param_changed = &parameter, .process = &process };
};
