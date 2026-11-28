//! Direct PipeWire audio control and event-driven discovery on the main context.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const Registry = @import("desktop-audio-registry.zig").Registry;
// Test builds account for service state and asynchronous callback allocations.
fn cast(comptime T: type, ptr: anytype) *T { return @ptrCast(@alignCast(ptr)); }
pub const Class = enum { output, input, playback, recording };
pub const State = struct { percent: f64, muted: bool = false };
pub const Node = struct {
    id: u32,
    class: Class,
    title: [256:0]u8 = @splat(0),
    name: [256:0]u8 = @splat(0),
    state: ?State = null,
    is_default: bool = false,
    running: bool = false,
    capture_sink: bool = false,
};
pub const Target = union(enum) { output, input, id: u32 };
pub fn target(text: []const u8) !Target {
    if (std.mem.eql(u8, text, "@DEFAULT_AUDIO_SINK@")) return .output;
    if (std.mem.eql(u8, text, "@DEFAULT_AUDIO_SOURCE@")) return .input;
    const id = std.fmt.parseInt(u32, text, 10) catch return error.InvalidAudioTarget;
    if (id == 0 or id == std.math.maxInt(u32)) return error.InvalidAudioTarget;
    return .{ .id = id };
}
pub const Change = union(enum) { volume: f64, mute: bool, toggle, step: i16, default };
pub const Result = union(enum) { value: State, failure: anyerror };
pub const Completion = *const fn (?*anyopaque, Result) void;
fn copy(buffer: []u8, text: [*c]const u8) void {
    if (text == null) return;
    const source = std.mem.span(text);
    @memcpy(buffer[0..@min(buffer.len - 1, source.len)], source[0..@min(buffer.len - 1, source.len)]);
}
fn classOf(text: []const u8) ?Class {
    for ([_][]const u8{ "Audio/Sink", "Audio/Source", "Stream/Output/Audio", "Stream/Input/Audio" }, [_]Class{ .output, .input, .playback, .recording }) |name, class| {
        if (std.mem.eql(u8, text, name)) return class;
    }
    return null;
}
fn isTrue(value: [*c]const u8) bool {
    return value != null and std.mem.eql(u8, std.mem.span(value), "true");
}
fn isActiveRecording(item: Node) bool {
    return item.class == .recording and item.running and !item.capture_sink;
}
const Mixer = @import("desktop-audio-mixer.zig");
pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    callback: *const fn (?*anyopaque, *Service) void,
    data: ?*anyopaque,
    registry: ?*Registry = null,
    calls: std.ArrayList(*Call) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    timer: u32 = 0,
    idle: u32 = 0,
    epoch: u64 = 0,
    refs: usize = 1,
    ready: bool = false,
    stopped: bool = false,

    pub fn create(a: std.mem.Allocator, io: std.Io, callback: *const fn (?*anyopaque, *Service) void, data: ?*anyopaque) !*Service {
        const self = try a.create(Service);
        self.* = .{ .allocator = a, .io = io, .callback = callback, .data = data };
        self.connect();
        self.timer = mainloop.timeoutSeconds(io, 5, self, maintain);
        return self;
    }
    pub fn destroy(self: *Service) void {
        self.stopped = true;
        _ = mainloop.remove(self.io, self.timer);
        self.reset();
        self.unref();
    }
    fn unref(self: *Service) void {
        self.refs -= 1;
        if (self.refs == 0) {
            self.nodes.deinit(self.allocator);
            self.calls.deinit(self.allocator);
            self.allocator.destroy(self);
        }
    }
    fn reset(self: *Service) void {
        self.epoch +%= 1;
        self.ready = false;
        if (self.idle != 0) _ = mainloop.remove(self.io, self.idle);
        self.idle = 0;
        if (self.registry) |registry| registry.destroy();
        self.registry = null;
        self.nodes.clearRetainingCapacity();
        for (self.calls.items) |call| call.wake();
    }
    fn maintain(self: *Service) bool {
        if (self.registry == null) self.connect();
        return true;
    }
    fn connect(self: *Service) void {
        self.registry = Registry.create(self.allocator, self.io, &changed, self) catch null;
    }
    fn changed(data: ?*anyopaque) void {
        cast(Service, data).schedule();
    }
    fn schedule(self: *Service) void {
        if (!self.stopped and self.idle == 0) self.idle = mainloop.timeout(self.io, 0, self, updated);
    }
    fn updated(self: *Service) bool {
        self.idle = 0;
        if (self.registry) |registry| {
            if (registry.failed) {
                self.reset();
                self.notify();
                return false;
            }
            self.ready = registry.ready;
        }
        self.rebuild();
        self.notify();
        return false;
    }
    fn notify(self: *Service) void {
        if (!self.stopped) self.callback(self.data, self);
    }
    fn defaultId(self: *Service, class: [*:0]const u8) u32 {
        const registry = self.registry orelse return std.math.maxInt(u32);
        const name = registry.defaultName(std.mem.eql(u8, std.mem.span(class), "Audio/Sink")) orelse return std.math.maxInt(u32);
        for (registry.objects.items) |object| {
            if (object.kind != .node) continue;
            const node_name = object.property("node.name");
            const media = object.property("media.class");
            if (node_name != null and media != null and std.mem.eql(u8, std.mem.span(node_name), name) and std.mem.eql(u8, std.mem.span(media), std.mem.span(class))) return object.id;
        }
        return std.math.maxInt(u32);
    }
    fn rebuild(self: *Service) void {
        self.nodes.clearRetainingCapacity();
        if (!self.ready) return;
        const registry = self.registry orelse return;
        const output = self.defaultId("Audio/Sink");
        const input = self.defaultId("Audio/Source");
        for (registry.objects.items) |object| {
            if (object.kind != .node) continue;
            const media = object.property("media.class");
            if (media == null) continue;
            const class = classOf(std.mem.span(media)) orelse continue;
            var entry = Node{ .id = object.id, .class = class, .state = self.volume(object.id), .is_default = object.id == output or object.id == input, .running = object.running, .capture_sink = isTrue(object.property("stream.capture.sink")) };
            copy(&entry.name, object.property("node.name"));
            const title_keys: [4][*:0]const u8 = if (class == .playback or class == .recording) .{ "application.name", "node.description", "node.nick", "node.name" } else .{ "node.description", "application.name", "node.nick", "node.name" };
            for (title_keys) |key| {
                const title = object.property(key);
                if (title != null) {
                    copy(&entry.title, title);
                    break;
                }
            }
            self.nodes.append(self.allocator, entry) catch @panic("out of memory");
        }
    }
    pub fn activeRecording(self: *const Service) bool {
        if (!self.ready) return false;
        for (self.nodes.items) |item| if (isActiveRecording(item)) return true;
        return false;
    }
    pub fn node(self: *Service, wanted: Target) ?Node {
        if (!self.ready) return null;
        const id = switch (wanted) {
            .output => self.defaultId("Audio/Sink"),
            .input => self.defaultId("Audio/Source"),
            .id => |id| id,
        };
        for (self.nodes.items) |item| if (item.id == id) return item;
        return null;
    }
    fn volume(self: *Service, id: u32) ?State {
        var control = Mixer.read(self.registry orelse return null, id) orelse return null;
        return .{ .percent = control.percent(), .muted = control.muted };
    }
    pub fn state(self: *Service, wanted: Target) ?State {
        const item = self.node(wanted) orelse return null;
        return self.volume(item.id);
    }
    pub fn apply(self: *Service, wanted: Target, change: Change, cancel: *mainloop.Cancellable, callback: Completion, data: ?*anyopaque) void {
        const item = self.node(wanted) orelse {
            callback(data, .{ .failure = error.AudioUnavailable });
            return;
        };
        if (cancel.isCancelled()) {
            callback(data, .{ .failure = error.Cancelled });
            return;
        }
        var ok: c_int = 0;
        var expected: ?State = null;
        if (change == .default) {
            switch (item.class) {
                .output, .input => {},
                else => {
                    callback(data, .{ .failure = error.InvalidDefaultDevice });
                    return;
                },
            }
            ok = @intFromBool(self.registry.?.setDefault(item.class == .output, std.mem.sliceTo(&item.name, 0)));
        } else {
            const current = self.state(wanted) orelse {
                callback(data, .{ .failure = error.AudioUnavailable });
                return;
            };
            expected = current;
            switch (change) {
                .volume => |percent| expected.?.percent = std.math.clamp(percent, 0, 100),
                .step => |delta| {
                    expected.?.percent = std.math.clamp(current.percent + @as(f64, @floatFromInt(delta)), 0, 100);
                    expected.?.muted = false;
                },
                .mute => |muted| expected.?.muted = muted,
                .toggle => expected.?.muted = !current.muted,
                .default => unreachable,
            }
            if (change == .volume and !std.math.isFinite(change.volume)) {
                callback(data, .{ .failure = error.InvalidVolume });
                return;
            }
            var control = Mixer.read(self.registry.?, item.id) orelse {
                callback(data, .{ .failure = error.AudioUnavailable });
                return;
            };
            ok = @intFromBool(control.write(if (change == .volume or change == .step) expected.?.percent else null, if (change == .volume) null else expected.?.muted));
        }
        if (ok == 0) {
            callback(data, .{ .failure = error.AudioWriteRejected });
            return;
        }
        const ticket = self.registry.?.sync() orelse {
            callback(data, .{ .failure = error.AudioWriteRejected });
            return;
        };
        const call = self.allocator.create(Call) catch @panic("out of memory");
        call.* = .{ .service = self, .epoch = self.epoch, .target = .{ .id = item.id }, .ticket = ticket, .expected = expected, .default_class = if (change == .default) item.class else null, .callback = callback, .data = data, .parent = cancel.ref(), .deadline = std.Io.Clock.awake.now(self.io).toMicroseconds() + 4_000_000 };
        self.refs += 1;
        self.calls.append(self.allocator, call) catch @panic("out of memory");
        call.wake();
    }
};
const Call = struct {
    service: *Service,
    epoch: u64,
    target: Target,
    ticket: u64,
    expected: ?State,
    default_class: ?Class,
    callback: Completion,
    data: ?*anyopaque,
    parent: *mainloop.Cancellable,
    source: u32 = 0,
    deadline: i64,
    fn wake(self: *Call) void {
        if (self.source != 0) _ = mainloop.remove(self.service.io, self.source);
        self.source = mainloop.idle(self.service.io, self, poll);
    }
    fn again(self: *Call) void {
        self.source = mainloop.timeout(self.service.io, 5, self, poll);
    }
    fn poll(self: *Call) bool {
        self.source = 0;
        if (self.parent.isCancelled()) {
            self.finish(.{ .failure = error.Cancelled });
            return false;
        }
        if (self.service.stopped or self.epoch != self.service.epoch or self.service.registry == null or self.service.registry.?.failed) {
            self.finish(.{ .failure = error.AudioDisconnected });
            return false;
        }
        if (std.Io.Clock.awake.now(self.service.io).toMicroseconds() >= self.deadline) {
            self.finish(.{ .failure = error.AudioTimedOut });
            return false;
        }
        const registry = self.service.registry.?;
        if (registry.find(self.target.id) == null) {
            self.finish(.{ .failure = error.AudioUnavailable });
            return false;
        }
        if (registry.completed < self.ticket) {
            self.again();
            return false;
        }
        const actual = self.service.state(self.target) orelse {
            self.again();
            return false;
        };
        const confirmed = if (self.expected) |expected|
            @abs(actual.percent - expected.percent) < 0.01 and actual.muted == expected.muted
        else
            self.service.defaultId(if (self.default_class.? == .output) "Audio/Sink" else "Audio/Source") == self.target.id;
        if (confirmed) self.finish(.{ .value = actual }) else self.again();
        return false;
    }
    fn finish(self: *Call, answer: Result) void {
        const service = self.service;
        for (service.calls.items, 0..) |call, i| if (call == self) {
            _ = service.calls.swapRemove(i);
            break;
        };
        self.callback(self.data, answer);
        self.parent.unref();
        service.allocator.destroy(self);
        service.unref();
    }
};

/// Drive callbacks for the legacy standalone JSON stream.
pub fn dispatch(io: std.Io) void {
    while (mainloop.iteration(io, false)) {}
}

pub const Feedback = @import("desktop-feedback.zig").Feedback;
comptime {
    // Include parser tests even when only control APIs are used.
    _ = Feedback;
    _ = @import("desktop-audio-defaults.zig");
    _ = Mixer;
    _ = @import("desktop-audio-registry.zig");
}

test "audio target names and media classes are explicit" {
    try std.testing.expectEqual(Target.output, try target("@DEFAULT_AUDIO_SINK@"));
    try std.testing.expectEqual(Target{ .id = 42 }, try target("42"));
    try std.testing.expectError(error.InvalidAudioTarget, target("0"));
    try std.testing.expectError(error.InvalidAudioTarget, target("4294967295"));
    try std.testing.expectEqual(Class.recording, classOf("Stream/Input/Audio").?);
    try std.testing.expectEqual(@as(?Class, null), classOf("Video/Source"));
    try std.testing.expect(isActiveRecording(.{ .id = 1, .class = .recording, .running = true }));
    try std.testing.expect(!isActiveRecording(.{ .id = 2, .class = .recording, .running = false }));
    try std.testing.expect(!isActiveRecording(.{ .id = 3, .class = .recording, .running = true, .capture_sink = true }));
    try std.testing.expect(!isActiveRecording(.{ .id = 4, .class = .playback, .running = true }));
}
