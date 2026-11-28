//! Bounded PCM WAV decoding and event playback through a native PipeWire node.
//! The node offers one 32-bit float DSP port per output channel, like a JACK
//! client, so the sink links it without a converter in this process; the
//! sound is resampled to the graph rate as it plays.
const std = @import("std");
const spa = @import("desktop-spa.zig");
const Pod = @import("desktop-audio-pod.zig");
const pipewire = @import("desktop-pipewire-node.zig");
const util = @import("desktop-util.zig");
const libc = @import("desktop-libc.zig");

const Wave = struct {
    samples: []const u8,
    rate: u32,
    channels: u16,

    fn parse(bytes: []const u8) !Wave {
        if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.InvalidWave;
        const end = @as(usize, std.mem.readInt(u32, bytes[4..8], .little)) + 8;
        if (end > bytes.len or end < 12) return error.InvalidWave;
        var format: ?[]const u8 = null;
        var samples: ?[]const u8 = null;
        var offset: usize = 12;
        while (offset + 8 <= end) {
            const size = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
            const start = offset + 8;
            if (size > end - start) return error.InvalidWave;
            const chunk = bytes[start..][0..size];
            if (std.mem.eql(u8, bytes[offset..][0..4], "fmt ")) format = chunk;
            if (std.mem.eql(u8, bytes[offset..][0..4], "data")) samples = chunk;
            offset = start + size + (size & 1);
        }
        const fmt = format orelse return error.InvalidWave;
        const data = samples orelse return error.InvalidWave;
        if (fmt.len < 16 or std.mem.readInt(u16, fmt[0..2], .little) != 1 or std.mem.readInt(u16, fmt[14..16], .little) != 16) return error.UnsupportedWave;
        const channels = std.mem.readInt(u16, fmt[2..4], .little);
        const rate = std.mem.readInt(u32, fmt[4..8], .little);
        if (channels < 1 or channels > 2 or rate < 8000 or rate > 192000) return error.UnsupportedWave;
        const stride = channels * 2;
        if (std.mem.readInt(u16, fmt[12..14], .little) != stride or data.len == 0 or data.len % stride != 0) return error.InvalidWave;
        return .{ .samples = data, .rate = rate, .channels = channels };
    }
};

/// The largest graph quantum a DSP port buffer must hold, as pw_filter assumes.
const quantum_limit = 8192;

pub const Feedback = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    node: ?*pipewire.Node = null,
    bytes: ?[]u8 = null,
    wave: Wave = undefined,
    /// Playback position in source frames; advanced on the node thread.
    position: f64 = 0,
    deadline: i64 = 0,

    pub fn playing(self: *Feedback) bool {
        const node = self.node orelse return false;
        return switch (node.state.load(.acquire)) {
            .connecting, .paused, .streaming => util.monotonicTime(self.io) < self.deadline,
            .failed, .finished => false,
        };
    }

    pub fn play(self: *Feedback, path: [*:0]const u8) void {
        if (self.playing()) return;
        self.deinit();
        const fd = libc.open(path, libc.O_RDONLY | libc.O_CLOEXEC | libc.O_NONBLOCK);
        if (fd < 0) return;
        defer _ = libc.close(fd);
        const scratch = self.allocator.alloc(u8, 4 * 1024 * 1024 + 1) catch return;
        defer self.allocator.free(scratch);
        var length: usize = 0;
        while (length < scratch.len) {
            const count = libc.read(fd, scratch[length..].ptr, scratch.len - length);
            if (count < 0) return;
            if (count == 0) break;
            length += @intCast(count);
        }
        if (length == scratch.len) return;
        const bytes = self.allocator.dupe(u8, scratch[0..length]) catch return;
        self.wave = Wave.parse(bytes) catch {
            self.allocator.free(bytes);
            return;
        };
        self.bytes = bytes;
        self.position = 0;
        var format: [256]u8 align(8) = undefined;
        var builder = Pod.Builder.init(&format, spa.SPA_TYPE_OBJECT_Format, spa.SPA_PARAM_EnumFormat) catch unreachable;
        builder.identifier(spa.SPA_FORMAT_mediaType, spa.SPA_MEDIA_TYPE_audio) catch unreachable;
        builder.identifier(spa.SPA_FORMAT_mediaSubtype, spa.SPA_MEDIA_SUBTYPE_dsp) catch unreachable;
        builder.identifier(spa.SPA_FORMAT_AUDIO_format, spa.SPA_AUDIO_FORMAT_DSP_F32) catch unreachable;
        const enum_format = builder.view().bytes;
        const ports = [_]pipewire.PortSpec{
            .{ .enum_format = enum_format, .properties = &.{ .{ "port.name", "output_FL" }, .{ "audio.channel", "FL" }, .{ "format.dsp", "32 bit float mono audio" } } },
            .{ .enum_format = enum_format, .properties = &.{ .{ "port.name", "output_FR" }, .{ "audio.channel", "FR" }, .{ "format.dsp", "32 bit float mono audio" } } },
        };
        // The session manager links audio streams by the stream format their
        // node reports: planar float stereo, one channel per DSP port.
        var stream: [256]u8 align(8) = undefined;
        var stream_builder = Pod.Builder.init(&stream, spa.SPA_TYPE_OBJECT_Format, spa.SPA_PARAM_EnumFormat) catch unreachable;
        stream_builder.identifier(spa.SPA_FORMAT_mediaType, spa.SPA_MEDIA_TYPE_audio) catch unreachable;
        stream_builder.identifier(spa.SPA_FORMAT_mediaSubtype, spa.SPA_MEDIA_SUBTYPE_raw) catch unreachable;
        stream_builder.identifier(spa.SPA_FORMAT_AUDIO_format, spa.SPA_AUDIO_FORMAT_F32P) catch unreachable;
        stream_builder.integer(spa.SPA_FORMAT_AUDIO_channels, 2) catch unreachable;
        stream_builder.ids(spa.SPA_FORMAT_AUDIO_position, &.{ spa.SPA_AUDIO_CHANNEL_FL, spa.SPA_AUDIO_CHANNEL_FR }) catch unreachable;
        self.deadline = util.monotonicTime(self.io) + 5_000_000 + @as(i64, @intCast(self.wave.samples.len * 1_000_000 / (self.wave.rate * self.wave.channels * 2)));
        self.node = pipewire.Node.create(self.allocator, .{
            .properties = &.{
                .{ "media.type", "Audio" },
                .{ "media.category", "Playback" },
                .{ "media.role", "Event" },
                .{ "media.class", "Stream/Output/Audio" },
                .{ "node.name", "desktop-feedback" },
                .{ "node.description", "Volume feedback" },
                .{ "node.autoconnect", "true" },
            },
            .ports = &ports,
            .format = stream_builder.view().bytes,
        }, .{ .context = self, .format = &format_buffers, .process = &process }) catch null;
        if (self.node == null) self.deinit();
    }

    pub fn deinit(self: *Feedback) void {
        if (self.node) |node| node.destroy();
        if (self.bytes) |bytes| self.allocator.free(bytes);
        self.* = .{ .allocator = self.allocator, .io = self.io };
    }

    fn format_buffers(_: *anyopaque, _: u32, _: []const u8, out: []align(8) u8) ?[]const u8 {
        var builder = Pod.Builder.init(out, spa.SPA_TYPE_OBJECT_ParamBuffers, spa.SPA_PARAM_Buffers) catch return null;
        builder.integer(spa.SPA_PARAM_BUFFERS_buffers, 2) catch return null;
        builder.integer(spa.SPA_PARAM_BUFFERS_blocks, 1) catch return null;
        builder.integer(spa.SPA_PARAM_BUFFERS_size, quantum_limit * @sizeOf(f32)) catch return null;
        builder.integer(spa.SPA_PARAM_BUFFERS_stride, @sizeOf(f32)) catch return null;
        return builder.view().bytes;
    }

    /// Writes one quantum per channel, interpolating source frames linearly.
    fn process(context: *anyopaque, cycle: *pipewire.Cycle) void {
        const self: *Feedback = @ptrCast(@alignCast(context));
        if (cycle.rate == 0) return;
        const frames_total = self.wave.samples.len / (@as(usize, self.wave.channels) * 2);
        const step = @as(f64, @floatFromInt(self.wave.rate)) / @as(f64, @floatFromInt(cycle.rate));
        var frames: usize = @intCast(@min(cycle.duration, quantum_limit));
        for (cycle.buffers) |buffer| if (buffer) |value| {
            frames = @min(frames, value.data.len / @sizeOf(f32));
        };
        for (cycle.buffers, 0..) |buffer, channel| {
            const value = buffer orelse continue;
            const out: [*]align(1) f32 = @ptrCast(value.data.ptr);
            const source = @min(channel, self.wave.channels - 1);
            for (0..frames) |index| {
                const at = self.position + @as(f64, @floatFromInt(index)) * step;
                const first: usize = @intFromFloat(@floor(at));
                const weight: f32 = @floatCast(at - @floor(at));
                out[index] = (1 - weight) * self.sample(first, source, frames_total) + weight * self.sample(first + 1, source, frames_total);
            }
            value.chunk.* = .{ .offset = 0, .size = @intCast(frames * @sizeOf(f32)), .stride = @sizeOf(f32), .flags = 0 };
        }
        self.position += @as(f64, @floatFromInt(frames)) * step;
        // One silent quantum after the sound lets the sink drain its last samples.
        if (self.position >= @as(f64, @floatFromInt(frames_total)) + @as(f64, @floatFromInt(frames)) * step) cycle.finished = true;
    }

    fn sample(self: *const Feedback, frame: usize, channel: usize, frames_total: usize) f32 {
        if (frame >= frames_total) return 0;
        const at = (frame * self.wave.channels + channel) * 2;
        const value = std.mem.readInt(i16, self.wave.samples[at..][0..2], .little);
        return @as(f32, @floatFromInt(value)) / 32768.0;
    }
};

test "PCM WAV validates chunks, format, and complete frames" {
    var bytes: [48]u8 = @splat(0);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 40, .little);
    @memcpy(bytes[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], 48000, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], 4, .little);
    const wave = try Wave.parse(&bytes);
    try std.testing.expectEqual(@as(u32, 48000), wave.rate);
    try std.testing.expectEqual(@as(usize, 4), wave.samples.len);
    try std.testing.expectError(error.InvalidWave, Wave.parse(bytes[0..47]));
    std.mem.writeInt(u32, bytes[40..44], 1000, .little);
    try std.testing.expectError(error.InvalidWave, Wave.parse(&bytes));
    std.mem.writeInt(u32, bytes[40..44], 3, .little);
    try std.testing.expectError(error.InvalidWave, Wave.parse(&bytes));
    std.mem.writeInt(u32, bytes[40..44], 4, .little);
    std.mem.writeInt(u16, bytes[20..22], 3, .little);
    try std.testing.expectError(error.UnsupportedWave, Wave.parse(&bytes));
}

test "feedback resamples to the graph rate and finishes after a silent quantum" {
    var samples: [8]u8 = undefined;
    for (0..4) |index| std.mem.writeInt(i16, samples[index * 2 ..][0..2], @intCast(index * 8192), .little);
    var player = Feedback{ .allocator = std.testing.allocator, .io = std.testing.io, .wave = .{ .samples = &samples, .rate = 24000, .channels = 1 } };
    var left: [8]f32 = undefined;
    var right: [8]f32 = undefined;
    var chunks: [2]spa.spa_chunk = undefined;
    var buffers = [_]?pipewire.Buffer{ .{ .data = std.mem.sliceAsBytes(&left), .chunk = &chunks[0] }, .{ .data = std.mem.sliceAsBytes(&right), .chunk = &chunks[1] } };
    var cycle: pipewire.Cycle = .{ .duration = 8, .rate = 48000, .buffers = &buffers };
    Feedback.process(&player, &cycle);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.375 }, &left);
    try std.testing.expectEqualSlices(f32, &left, &right);
    try std.testing.expectEqual(@as(u32, 32), chunks[0].size);
    try std.testing.expect(!cycle.finished);
    Feedback.process(&player, &cycle);
    try std.testing.expect(cycle.finished);
    try std.testing.expectEqual(@as(f32, 0), left[0]);
}
