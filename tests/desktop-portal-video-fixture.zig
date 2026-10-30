//! Independent PipeWire consumer: require complete red and blue video frames.
const std = @import("std");
const p = @import("desktop").pipewire;
const Pod = @import("desktop").audio_pod;
const c = @import("desktop").gtk;
const libc = @import("desktop").libc;
const Consumer = struct {
    stream: ?*p.pw_stream = null,
    width: u32,
    height: u32,
    red: usize = 0,
    blue: usize = 0,
    failed: bool = false,
    fn process(data: ?*anyopaque) callconv(.c) void {
        const self: *Consumer = @ptrCast(@alignCast(data));
        const buffer = p.pw_stream_dequeue_buffer(self.stream) orelse return;
        defer _ = p.pw_stream_queue_buffer(self.stream, buffer);
        const raw = buffer.*.buffer;
        if (raw == null or raw.*.n_datas == 0) return;
        const pixels = raw.*.datas[0];
        if (pixels.data == null or pixels.chunk == null or pixels.chunk.*.size == 0) return;
        const size = self.width * self.height * 4;
        if (pixels.chunk.*.size != size or pixels.chunk.*.stride != self.width * 4 or pixels.chunk.*.offset + size > pixels.maxsize) {
            self.failed = true;
            return;
        }
        const bytes: [*]const u8 = @ptrCast(pixels.data);
        const offset = pixels.chunk.*.offset + (self.height / 2 * self.width + self.width / 2) * 4;
        const pixel = std.mem.readInt(u32, bytes[offset..][0..4], @import("builtin").cpu.arch.endian());
        const red = (pixel >> 16) & 255;
        const blue = pixel & 255;
        if (red > 240 and blue < 10) {
            self.red += 1;
            if (self.red == 1) _ = libc.write(1, "red\n", 4);
        }
        if (blue > 240 and red < 10) {
            self.blue += 1;
            if (self.blue == 1) _ = libc.write(1, "blue\n", 5);
        }
    }
    fn state(data: ?*anyopaque, _: p.pw_stream_state, value: p.pw_stream_state, _: [*c]const u8) callconv(.c) void {
        const self: *Consumer = @ptrCast(@alignCast(data));
        if (value == p.PW_STREAM_STATE_ERROR) self.failed = true;
    }
    const events: p.pw_stream_events = .{ .version = p.PW_VERSION_STREAM_EVENTS, .state_changed = &state, .process = &process };
};
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len != 4) return error.ExpectedNodeAndDimensions;
    const node = try std.fmt.parseInt(u32, args[1], 10);
    var consumer = Consumer{ .width = try std.fmt.parseInt(u32, args[2], 10), .height = try std.fmt.parseInt(u32, args[3], 10) };
    p.pw_init(null, null);
    const main_loop = p.pw_main_loop_new(null) orelse return error.NoLoop;
    defer p.pw_main_loop_destroy(main_loop);
    const loop = p.pw_main_loop_get_loop(main_loop);
    consumer.stream = p.pw_stream_new_simple(loop, "Portal video test consumer", p.pw_properties_new(@as([*:0]const u8, "media.type"), @as([*:0]const u8, "Video"), @as([*:0]const u8, "media.category"), @as([*:0]const u8, "Capture"), @as(?*anyopaque, null)), &Consumer.events, &consumer) orelse return error.NoStream;
    defer p.pw_stream_destroy(consumer.stream);
    var bytes: [512]u8 align(8) = undefined;
    var format = try Pod.Builder.init(&bytes, p.SPA_TYPE_OBJECT_Format, p.SPA_PARAM_EnumFormat);
    try format.identifier(p.SPA_FORMAT_mediaType, p.SPA_MEDIA_TYPE_video);
    try format.identifier(p.SPA_FORMAT_mediaSubtype, p.SPA_MEDIA_SUBTYPE_raw);
    try format.identifier(p.SPA_FORMAT_VIDEO_format, if (@import("builtin").cpu.arch.endian() == .little) p.SPA_VIDEO_FORMAT_BGRx else p.SPA_VIDEO_FORMAT_xRGB);
    try format.pair(p.SPA_FORMAT_VIDEO_size, p.SPA_TYPE_Rectangle, consumer.width, consumer.height);
    try format.pair(p.SPA_FORMAT_VIDEO_framerate, p.SPA_TYPE_Fraction, 30, 1);
    var params = [_][*c]const p.spa_pod{@ptrCast(&bytes)};
    if (p.pw_stream_connect(consumer.stream, p.PW_DIRECTION_INPUT, node, p.PW_STREAM_FLAG_AUTOCONNECT | p.PW_STREAM_FLAG_MAP_BUFFERS, &params, params.len) < 0) return error.ConnectFailed;
    const iface: *p.spa_interface = @ptrCast(@alignCast(loop.?.*.control));
    const methods: *const p.spa_loop_control_methods = @ptrCast(@alignCast(iface.cb.funcs));
    methods.enter.?(iface.cb.data);
    defer methods.leave.?(iface.cb.data);
    const deadline = c.g_get_monotonic_time() + 15 * 1000000;
    while (!consumer.failed and (consumer.red < 2 or consumer.blue < 2) and c.g_get_monotonic_time() < deadline) {
        if (methods.iterate.?(iface.cb.data, 50) < 0) break;
    }
    if (consumer.failed or consumer.red < 2 or consumer.blue < 2) return error.MissingVideoFrames;
}
