//! Native, main-context WirePlumber audio control and event-driven node discovery.
const std = @import("std");
const c = @import("gtk");
const w = @import("audio-api");
// Test builds account for service state and asynchronous callback allocations.
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
var initialized = false;
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
fn signal(object: anytype, name: [*:0]const u8, callback: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(object, name, @ptrCast(callback), data, null, 0);
}
pub const Class = enum { output, input, playback, recording };
pub const State = struct { percent: f64, muted: bool = false };
pub const Node = struct {
    id: u32,
    class: Class,
    title: [256:0]u8 = @splat(0),
    name: [256:0]u8 = @splat(0),
    state: ?State = null,
    is_default: bool = false,
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
fn volume(mixer: [*c]w.WpPlugin, id: u32) ?State {
    var dict: ?*c.GVariant = null;
    c.g_signal_emit_by_name(mixer, "get-volume", id, &dict);
    if (dict == null) return null;
    defer c.g_variant_unref(dict);
    const value = c.g_variant_lookup_value(dict, "volume", @ptrCast(@as([*:0]const u8, "d"))) orelse return null;
    defer c.g_variant_unref(value);
    const percent = c.g_variant_get_double(value) * 100;
    if (!std.math.isFinite(percent) or percent < 0) return null;
    const mute = c.g_variant_lookup_value(dict, "mute", @ptrCast(@as([*:0]const u8, "b")));
    defer if (mute) |v| c.g_variant_unref(v);
    return .{ .percent = @min(percent, 100), .muted = if (mute) |v| c.g_variant_get_boolean(v) != 0 else false };
}
const Load = struct { service: *Service, epoch: u64 };
pub const Service = struct {
    callback: *const fn (?*anyopaque, *Service) void,
    data: ?*anyopaque,
    core: ?*w.WpCore = null,
    manager: ?*w.WpObjectManager = null,
    mixer: [*c]w.WpPlugin = null,
    defaults: [*c]w.WpPlugin = null,
    nodes: std.ArrayList(Node) = .empty,
    cancel: *c.GCancellable,
    timer: c.guint = 0,
    idle: c.guint = 0,
    epoch: u64 = 0,
    loading: usize = 0,
    refs: usize = 1,
    ready: bool = false,
    stopped: bool = false,

    pub fn create(callback: *const fn (?*anyopaque, *Service) void, data: ?*anyopaque) !*Service {
        const self = try a.create(Service);
        if (!initialized) {
            w.wp_init(w.WP_INIT_ALL);
            initialized = true;
        }
        self.* = .{ .callback = callback, .data = data, .cancel = c.g_cancellable_new().? };
        self.connect();
        self.timer = c.g_timeout_add_seconds(5, &maintain, self);
        return self;
    }
    pub fn destroy(self: *Service) void {
        self.stopped = true;
        _ = c.g_source_remove(self.timer);
        c.g_cancellable_cancel(self.cancel);
        self.reset();
        self.unref();
    }
    fn unref(self: *Service) void {
        self.refs -= 1;
        if (self.refs == 0) {
            self.nodes.deinit(a);
            c.g_object_unref(self.cancel);
            a.destroy(self);
        }
    }
    fn reset(self: *Service) void {
        self.epoch +%= 1;
        self.ready = false;
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        self.idle = 0;
        for ([_]c.gpointer{ self.mixer, self.defaults, self.manager, self.core }) |object| if (object) |value| {
            _ = c.g_signal_handlers_disconnect_matched(value, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        };
        if (self.mixer != null) c.g_object_unref(self.mixer);
        if (self.defaults != null) c.g_object_unref(self.defaults);
        if (self.manager) |manager| c.g_object_unref(manager);
        if (self.core) |core| {
            w.wp_core_disconnect(core);
            c.g_object_unref(core);
        }
        self.mixer = null;
        self.defaults = null;
        self.manager = null;
        self.core = null;
        self.nodes.clearRetainingCapacity();
    }
    fn maintain(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Service, data);
        if (self.core == null) self.connect();
        return 1;
    }
    fn connect(self: *Service) void {
        self.core = w.wp_core_new(null, null, null) orelse return;
        self.manager = w.wp_object_manager_new() orelse {
            self.reset();
            return;
        };
        w.wp_object_manager_add_interest(self.manager, w.wp_node_get_type(), @as(?*anyopaque, null));
        w.wp_object_manager_request_object_features(self.manager, w.wp_node_get_type(), w.WP_PIPEWIRE_OBJECT_FEATURES_MINIMAL);
        signal(self.core, "disconnected", &disconnected, self);
        signal(self.manager, "installed", &installed, self);
        signal(self.manager, "objects-changed", &changed, self);
        if (w.wp_core_connect(self.core) == 0) {
            self.reset();
            self.notify();
            return;
        }
        self.loading = 2;
        for ([_][*:0]const u8{ "libwireplumber-module-default-nodes-api", "libwireplumber-module-mixer-api" }) |name| {
            const load = a.create(Load) catch @panic("out of memory");
            load.* = .{ .service = self, .epoch = self.epoch };
            self.refs += 1;
            w.wp_core_load_component(self.core, name, "module", null, null, self.cancel, &loaded, load);
        }
    }
    fn loaded(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const load = cast(Load, data);
        const self = load.service;
        defer {
            a.destroy(load);
            self.unref();
        }
        const ok = w.wp_core_load_component_finish(@ptrCast(source), result, null) != 0;
        if (self.stopped or load.epoch != self.epoch) return;
        if (!ok) {
            self.reset();
            self.notify();
            return;
        }
        self.loading -= 1;
        if (self.loading != 0) return;
        self.mixer = w.wp_plugin_find(self.core, "mixer-api");
        self.defaults = w.wp_plugin_find(self.core, "default-nodes-api");
        if (self.mixer == null or self.defaults == null) {
            self.reset();
            self.notify();
            return;
        }
        c.g_object_set(self.mixer, "scale", @as(c_int, 1), @as(?*anyopaque, null));
        signal(self.mixer, "changed", &mixerChanged, self);
        signal(self.defaults, "changed", &changed, self);
        w.wp_core_install_object_manager(self.core, self.manager);
    }
    fn disconnected(_: ?*w.WpCore, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        self.reset();
        self.notify();
    }
    fn installed(_: ?*w.WpObjectManager, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        self.ready = true;
        self.schedule();
    }
    fn changed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        cast(Service, data).schedule();
    }
    fn mixerChanged(_: ?*anyopaque, _: u32, data: ?*anyopaque) callconv(.c) void {
        cast(Service, data).schedule();
    }
    fn schedule(self: *Service) void {
        if (!self.stopped and self.idle == 0) self.idle = c.g_timeout_add(0, &updated, self);
    }
    fn updated(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Service, data);
        self.idle = 0;
        self.rebuild();
        self.notify();
        return 0;
    }
    fn notify(self: *Service) void {
        if (!self.stopped) self.callback(self.data, self);
    }
    fn defaultId(self: *Service, class: [*:0]const u8) u32 {
        var id: u32 = std.math.maxInt(u32);
        if (self.defaults != null) c.g_signal_emit_by_name(self.defaults, "get-default-node", class, &id);
        return id;
    }
    fn rebuild(self: *Service) void {
        self.nodes.clearRetainingCapacity();
        if (!self.ready) return;
        const iterator = w.wp_object_manager_new_iterator(self.manager) orelse return;
        defer w.wp_iterator_unref(iterator);
        const output = self.defaultId("Audio/Sink");
        const input = self.defaultId("Audio/Source");
        var value = std.mem.zeroes(c.GValue);
        while (w.wp_iterator_next(iterator, &value) != 0) {
            defer c.g_value_unset(&value);
            const object: *w.WpPipewireObject = @ptrCast(w.g_value_get_object(&value) orelse continue);
            const media = w.wp_pipewire_object_get_property(object, "media.class");
            if (media == null) continue;
            const class = classOf(std.mem.span(media)) orelse continue;
            const id = w.wp_proxy_get_bound_id(@ptrCast(object));
            var entry = Node{ .id = id, .class = class, .state = volume(self.mixer, id), .is_default = id == output or id == input };
            copy(&entry.name, w.wp_pipewire_object_get_property(object, "node.name"));
            for ([_][*:0]const u8{ "node.description", "application.name", "node.nick", "node.name" }) |key| {
                const title = w.wp_pipewire_object_get_property(object, key);
                if (title != null) {
                    copy(&entry.title, title);
                    break;
                }
            }
            self.nodes.append(a, entry) catch @panic("out of memory");
        }
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
    pub fn state(self: *Service, wanted: Target) ?State {
        const item = self.node(wanted) orelse return null;
        return volume(self.mixer, item.id);
    }
    pub fn apply(self: *Service, wanted: Target, change: Change, cancel: *c.GCancellable, callback: Completion, data: ?*anyopaque) void {
        const item = self.node(wanted) orelse {
            callback(data, .{ .failure = error.AudioUnavailable });
            return;
        };
        if (c.g_cancellable_is_cancelled(cancel) != 0) {
            callback(data, .{ .failure = error.Cancelled });
            return;
        }
        var ok: c.gboolean = 0;
        var expected: ?State = null;
        if (change == .default) {
            const class: [*:0]const u8 = switch (item.class) {
                .output => "Audio/Sink",
                .input => "Audio/Source",
                else => {
                    callback(data, .{ .failure = error.InvalidDefaultDevice });
                    return;
                },
            };
            c.g_signal_emit_by_name(self.defaults, "set-default-configured-node-name", class, @as([*:0]const u8, &item.name), &ok);
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
            const builder = w.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
            defer w.g_variant_builder_unref(builder);
            switch (change) {
                .volume => |percent| {
                    if (!std.math.isFinite(percent)) {
                        callback(data, .{ .failure = error.InvalidVolume });
                        return;
                    }
                    w.g_variant_builder_add(builder, "{sv}", @as([*:0]const u8, "volume"), c.g_variant_new("d", std.math.clamp(percent, 0, 100) / 100));
                },
                .step => |delta| {
                    w.g_variant_builder_add(builder, "{sv}", @as([*:0]const u8, "volume"), c.g_variant_new("d", std.math.clamp(current.percent + @as(f64, @floatFromInt(delta)), 0, 100) / 100));
                    w.g_variant_builder_add(builder, "{sv}", @as([*:0]const u8, "mute"), c.g_variant_new("b", @as(c_int, 0)));
                },
                .mute, .toggle => w.g_variant_builder_add(builder, "{sv}", @as([*:0]const u8, "mute"), c.g_variant_new("b", @as(c_int, @intFromBool(if (change == .mute) change.mute else !current.muted)))),
                .default => unreachable,
            }
            const dict = w.g_variant_ref_sink(w.g_variant_builder_end(builder));
            defer c.g_variant_unref(dict);
            c.g_signal_emit_by_name(self.mixer, "set-volume", item.id, dict, &ok);
        }
        if (ok == 0) {
            callback(data, .{ .failure = error.AudioWriteRejected });
            return;
        }
        const call = a.create(Call) catch @panic("out of memory");
        call.* = .{ .service = self, .epoch = self.epoch, .target = .{ .id = item.id }, .expected = expected, .default_class = if (change == .default) item.class else null, .callback = callback, .data = data, .cancel = c.g_cancellable_new().?, .parent = cast(c.GCancellable, c.g_object_ref(cancel)) };
        self.refs += 1;
        call.parent_signal = c.g_signal_connect_data(cancel, "cancelled", @ptrCast(&Call.cancelled), call, null, 0);
        call.timer = c.g_timeout_add(4000, &Call.timedOut, call);
        _ = w.wp_core_sync(self.core, call.cancel, &Call.synced, call);
    }
};
const Call = struct {
    service: *Service,
    epoch: u64,
    target: Target,
    expected: ?State,
    default_class: ?Class,
    callback: Completion,
    data: ?*anyopaque,
    cancel: *c.GCancellable,
    parent: *c.GCancellable,
    parent_signal: c.gulong = 0,
    timer: c.guint = 0,
    timed_out: bool = false,
    fn cancelled(_: ?*c.GCancellable, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Call, data);
        c.g_cancellable_cancel(self.cancel);
        if (!self.service.stopped and self.epoch == self.service.epoch) {
            self.service.reset();
            self.service.notify();
        }
    }
    fn timedOut(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Call, data);
        self.timer = 0;
        self.timed_out = true;
        c.g_cancellable_cancel(self.cancel);
        // WirePlumber completes sync tasks only on a reply or disconnect.
        // Drop this client connection to release a stalled request immediately.
        if (!self.service.stopped and self.epoch == self.service.epoch) {
            self.service.reset();
            self.service.notify();
        }
        return 0;
    }
    fn failure(self: *Call) ?anyerror {
        if (self.timed_out) return error.AudioTimedOut;
        if (c.g_cancellable_is_cancelled(self.parent) != 0) return error.Cancelled;
        if (self.service.stopped or self.epoch != self.service.epoch) return error.AudioDisconnected;
        return null;
    }
    fn synced(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Call, data);
        const ok = w.wp_core_sync_finish(@ptrCast(source), result, null) != 0;
        if (self.failure()) |err| {
            self.finish(.{ .failure = err });
            return;
        }
        if (!ok) {
            self.finish(.{ .failure = error.AudioDisconnected });
            return;
        }
        const actual = self.service.state(self.target) orelse {
            self.finish(.{ .failure = error.AudioUnavailable });
            return;
        };
        const confirmed = if (self.expected) |expected|
            @abs(actual.percent - expected.percent) < 0.01 and actual.muted == expected.muted
        else
            self.service.defaultId(if (self.default_class.? == .output) "Audio/Sink" else "Audio/Source") == self.target.id;
        if (confirmed) {
            self.finish(.{ .value = actual });
            return;
        }
        // A core sync can precede the mixer's asynchronous Props refresh. Wait
        // for that refresh before allowing the next relative volume step.
        _ = c.g_timeout_add(5, &retry, self);
    }
    fn retry(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Call, data);
        if (self.failure()) |err| self.finish(.{ .failure = err }) else _ = w.wp_core_sync(self.service.core, self.cancel, &synced, self);
        return 0;
    }
    fn finish(self: *Call, answer: Result) void {
        const service = self.service;
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        c.g_signal_handler_disconnect(self.parent, self.parent_signal);
        self.callback(self.data, answer);
        c.g_object_unref(self.cancel);
        c.g_object_unref(self.parent);
        a.destroy(self);
        service.unref();
    }
};

/// Drive callbacks for the legacy standalone JSON stream.
pub fn dispatch() void {
    while (c.g_main_context_iteration(null, 0) != 0) {}
}

pub const Feedback = @import("desktop-feedback.zig").Feedback;
comptime {
    // Include the feedback parser tests even when only control APIs are used.
    _ = Feedback;
}

test "audio target names and media classes are explicit" {
    try std.testing.expectEqual(Target.output, try target("@DEFAULT_AUDIO_SINK@"));
    try std.testing.expectEqual(Target{ .id = 42 }, try target("42"));
    try std.testing.expectError(error.InvalidAudioTarget, target("0"));
    try std.testing.expectError(error.InvalidAudioTarget, target("4294967295"));
    try std.testing.expectEqual(Class.recording, classOf("Stream/Input/Audio").?);
    try std.testing.expectEqual(@as(?Class, null), classOf("Video/Source"));
}
