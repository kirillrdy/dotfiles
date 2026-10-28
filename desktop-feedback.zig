//! Bounded PCM WAV decoding and native PipeWire event playback.
const std = @import("std");
const p = @import("pipewire");
const c = @import("gtk");
const libc = @import("libc");
const a = std.heap.page_allocator;
var initialized = false;

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

pub const Feedback = struct {
    loop: ?*p.pw_thread_loop = null,
    stream: ?*p.pw_stream = null,
    bytes: ?[]u8 = null,
    wave: Wave = undefined,
    offset: usize = 0,
    active: bool = false,
    draining: bool = false,
    deadline: i64 = 0,

    pub fn playing(self: *Feedback) bool {
        const loop = self.loop orelse return false;
        p.pw_thread_loop_lock(loop);
        defer p.pw_thread_loop_unlock(loop);
        return self.active and c.g_get_monotonic_time() < self.deadline;
    }

    pub fn play(self: *Feedback, path: [*:0]const u8) void {
        if (self.playing()) return;
        self.deinit();
        const fd = libc.open(path, libc.O_RDONLY | libc.O_CLOEXEC | libc.O_NONBLOCK);
        if (fd < 0) return;
        defer _ = libc.close(fd);
        const scratch = a.alloc(u8, 4 * 1024 * 1024 + 1) catch return;
        defer a.free(scratch);
        var length: usize = 0;
        while (length < scratch.len) {
            const count = libc.read(fd, scratch[length..].ptr, scratch.len - length);
            if (count < 0) return;
            if (count == 0) break;
            length += @intCast(count);
        }
        if (length == scratch.len) return;
        const bytes = a.dupe(u8, scratch[0..length]) catch return;
        self.wave = Wave.parse(bytes) catch {
            a.free(bytes);
            return;
        };
        self.bytes = bytes;
        if (!initialized) {
            p.pw_init(null, null);
            initialized = true;
        }
        const loop = p.pw_thread_loop_new("desktop-feedback", null) orelse {
            self.deinit();
            return;
        };
        self.loop = loop;
        self.stream = p.pw_stream_new_simple(p.pw_thread_loop_get_loop(loop), "Volume feedback", p.pw_properties_new(@as([*:0]const u8, "media.type"), @as([*:0]const u8, "Audio"), @as([*:0]const u8, "media.category"), @as([*:0]const u8, "Playback"), @as([*:0]const u8, "media.role"), @as([*:0]const u8, "Event"), @as(?*anyopaque, null)), &events, self) orelse {
            self.deinit();
            return;
        };
        // SPA object with five scalar properties; all pods are aligned to 8 bytes.
        const Property = extern struct { key: u32, flags: u32 = 0, size: u32 = 4, kind: u32, value: u32, padding: u32 = 0 };
        const Format = extern struct { size: u32 = @sizeOf(@This()) - 8, kind: u32 = p.SPA_TYPE_Object, object_type: u32 = p.SPA_TYPE_OBJECT_Format, id: u32 = p.SPA_PARAM_EnumFormat, props: [5]Property };
        const format: Format = .{ .props = .{
            .{ .key = p.SPA_FORMAT_mediaType, .kind = p.SPA_TYPE_Id, .value = p.SPA_MEDIA_TYPE_audio },
            .{ .key = p.SPA_FORMAT_mediaSubtype, .kind = p.SPA_TYPE_Id, .value = p.SPA_MEDIA_SUBTYPE_raw },
            .{ .key = p.SPA_FORMAT_AUDIO_format, .kind = p.SPA_TYPE_Id, .value = p.SPA_AUDIO_FORMAT_S16_LE },
            .{ .key = p.SPA_FORMAT_AUDIO_rate, .kind = p.SPA_TYPE_Int, .value = self.wave.rate },
            .{ .key = p.SPA_FORMAT_AUDIO_channels, .kind = p.SPA_TYPE_Int, .value = self.wave.channels },
        } };
        var params = [_][*c]const p.spa_pod{@ptrCast(&format)};
        self.active = true;
        self.deadline = c.g_get_monotonic_time() + 5_000_000 + @as(i64, @intCast(self.wave.samples.len * 1_000_000 / (self.wave.rate * self.wave.channels * 2)));
        if (p.pw_stream_connect(self.stream, p.PW_DIRECTION_OUTPUT, p.PW_ID_ANY, p.PW_STREAM_FLAG_AUTOCONNECT | p.PW_STREAM_FLAG_MAP_BUFFERS, &params, 1) < 0 or p.pw_thread_loop_start(loop) < 0) self.deinit();
    }

    pub fn deinit(self: *Feedback) void {
        if (self.loop) |loop| p.pw_thread_loop_stop(loop);
        if (self.stream) |stream| p.pw_stream_destroy(stream);
        if (self.loop) |loop| p.pw_thread_loop_destroy(loop);
        if (self.bytes) |bytes| a.free(bytes);
        self.* = .{};
    }

    fn process(data: ?*anyopaque) callconv(.c) void {
        const self: *Feedback = @ptrCast(@alignCast(data.?));
        if (self.draining) return;
        const buffer = p.pw_stream_dequeue_buffer(self.stream) orelse return;
        const spa = buffer.*.buffer;
        if (spa == null or spa.*.n_datas == 0) {
            _ = p.pw_stream_queue_buffer(self.stream, buffer);
            return;
        }
        const dest = &spa.*.datas[0];
        const stride: u32 = self.wave.channels * 2;
        const count = @min(self.wave.samples.len - self.offset, dest.maxsize - dest.maxsize % stride);
        if (dest.data == null or dest.chunk == null or count == 0) {
            _ = p.pw_stream_queue_buffer(self.stream, buffer);
            self.active = false;
            return;
        }
        @memcpy(@as([*]u8, @ptrCast(dest.data))[0..count], self.wave.samples[self.offset..][0..count]);
        dest.chunk.*.offset = 0;
        dest.chunk.*.stride = @intCast(stride);
        dest.chunk.*.size = @intCast(count);
        buffer.*.size = count / stride;
        self.offset += count;
        _ = p.pw_stream_queue_buffer(self.stream, buffer);
        if (self.offset == self.wave.samples.len) {
            self.draining = true;
            _ = p.pw_stream_flush(self.stream, true);
        }
    }
    fn drained(data: ?*anyopaque) callconv(.c) void {
        const self: *Feedback = @ptrCast(@alignCast(data.?));
        self.active = false;
    }
    fn stateChanged(data: ?*anyopaque, _: p.pw_stream_state, state: p.pw_stream_state, _: [*c]const u8) callconv(.c) void {
        if (state == p.PW_STREAM_STATE_ERROR or state == p.PW_STREAM_STATE_UNCONNECTED) drained(data);
    }
    const events = blk: {
        var value = std.mem.zeroes(p.pw_stream_events);
        value.version = p.PW_VERSION_STREAM_EVENTS;
        value.process = &process;
        value.drained = &drained;
        value.state_changed = &stateChanged;
        break :blk value;
    };
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
