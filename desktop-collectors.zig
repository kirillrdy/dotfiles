//! Shared collectors: blocking device/API queries run in GLib workers, never GTK.
const std = @import("std");
const c = @import("gtk");
const data = @import("waybar-panel.zig");
const u = @import("desktop-util.zig");
const audio = @import("audio");
const network = @import("network");
const battery = @import("battery");
const panel = @import("desktop-panel.zig");
const a = std.heap.page_allocator;
const kinds = [_][]const u8{ "monitors", "status", "disk", "codex" };
const intervals = [_]u32{ 1, 10, 10, 120 }; // Half-second ticks.

pub const Service = struct {
    panel: *panel.Service,
    icon: []const u8,
    sources: [4]Source = undefined,
    timer: c.guint = 0,
    dead: bool = false,
    revision: u64 = 0,
    battery_service: ?*battery.Service = null,
    battery_state: battery.State = .{},
    network_client: ?*network.Client = null,
    audio_service: ?*audio.Service = null,
    output_state: ?audio.State = null,
    input_state: ?audio.State = null,

    pub fn start(self: *Service) void {
        for (&self.sources, 0..) |*source, i| source.* = .{ .owner = self, .index = i };
        self.battery_service = battery.Service.create(&batteryChanged, self) catch null;
        self.audio_service = audio.Service.create(&audioChanged, self) catch null;
        self.network_client = network.Client.create(&networkChanged, self) catch null;
        _ = tick(self);
        self.timer = c.g_timeout_add(500, &tick, self);
    }

    pub fn refresh(self: *Service, kind: []const u8) void {
        if (self.dead) return;
        for (&self.sources, kinds) |*source, name| if (std.mem.eql(u8, kind, name)) {
            source.remaining = 0;
            if (!source.busy) source.launch();
        };
    }

    fn tick(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self: *Service = @ptrCast(@alignCast(ptr));
        const revision = self.panel.revision();
        for (&self.sources, kinds) |*source, kind| {
            // Initialize new panels without repeatedly repainting unchanged data.
            if (revision != self.revision) if (source.cached != null) source.publish(kind);
            if (source.remaining > 0) source.remaining -= 1;
            if (source.remaining == 0 and !source.busy) source.launch();
        }
        self.revision = revision;
        return 1;
    }

    fn networkChanged(ptr: ?*anyopaque, _: *network.Client) void {
        const self: *Service = @ptrCast(@alignCast(ptr));
        if (!self.dead) self.sources[1].publish("status");
    }
    fn audioChanged(ptr: ?*anyopaque, service: *audio.Service) void {
        const self: *Service = @ptrCast(@alignCast(ptr));
        self.output_state = service.state(.output);
        self.input_state = service.state(.input);
        if (!self.dead) self.sources[1].publish("status");
    }
    fn batteryChanged(ptr: ?*anyopaque, state: battery.State) void {
        const self: *Service = @ptrCast(@alignCast(ptr));
        self.battery_state = state;
        if (!self.dead) self.sources[1].publish("status");
    }
    pub fn deinit(self: *Service) void {
        self.dead = true;
        if (self.network_client) |client| client.destroy();
        if (self.battery_service) |service| service.destroy();
        if (self.audio_service) |service| service.destroy();
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        for (&self.sources) |*source| {
            while (source.busy) _ = c.g_main_context_iteration(null, 1);
            if (source.cached) |line| a.free(line);
        }
    }
};
const Source = struct {
    owner: *Service,
    index: usize,
    remaining: u32 = 0,
    busy: bool = false,
    cached: ?[:0]u8 = null,
    monitor: ?data.Monitor = null, // Accessed only by this source's worker.

    fn publish(self: *Source, kind: []const u8) void {
        const line = self.cached orelse return;
        if (self.index != 1 or std.mem.eql(u8, u.env("WB_PANEL_DEMO") orelse "", "1")) {
            self.owner.panel.update(kind, line);
            return;
        }
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var out = u.parse(alloc, line) catch return;
        if (self.owner.network_client) |client| data.addNetwork(alloc, &out, client.state()) catch return;
        data.addAudio(alloc, &out, self.owner.output_state, self.owner.input_state) catch return;
        data.addBattery(alloc, &out, self.owner.battery_state) catch return;
        const json = std.json.Stringify.valueAlloc(alloc, out, .{}) catch return;
        const terminated = alloc.dupeSentinel(u8, json, 0) catch return;
        self.owner.panel.update(kind, terminated);
    }
    fn launch(self: *Source) void {
        self.busy = true;
        self.remaining = intervals[self.index];
        const task = c.g_task_new(null, null, &done, self).?;
        c.g_task_set_task_data(task, self, null);
        c.g_task_run_in_thread(task, &work);
        c.g_object_unref(task);
    }

    fn work(task: ?*c.GTask, _: c.gpointer, ptr: c.gpointer, _: ?*c.GCancellable) callconv(.c) void {
        const self: *Source = @ptrCast(@alignCast(ptr));
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const demo = std.mem.eql(u8, u.env("WB_PANEL_DEMO") orelse "", "1");
        const result = blk: {
            if (self.index == 0) {
                if (self.monitor == null) self.monitor = data.Monitor.init(alloc) catch break :blk null;
                break :blk self.monitor.?.sample(alloc, demo) catch null;
            }
            break :blk data.sample(alloc, kinds[self.index], self.owner.icon, demo) catch null;
        };
        const line = if (result) |value| blk: {
            const json = std.json.Stringify.valueAlloc(alloc, value, .{}) catch break :blk null;
            break :blk a.dupeSentinel(u8, json, 0) catch null;
        } else null;
        // The task transports ownership; completion always runs on the GTK thread.
        if (line) |bytes| {
            const output = a.create(Output) catch {
                a.free(bytes);
                c.g_task_return_pointer(task, null, null);
                return;
            };
            output.* = .{ .bytes = bytes };
            c.g_task_return_pointer(task, output, null);
        } else c.g_task_return_pointer(task, null, null);
    }

    fn done(_: ?*c.GObject, result: ?*c.GAsyncResult, ptr: c.gpointer) callconv(.c) void {
        const self: *Source = @ptrCast(@alignCast(ptr));
        const output: ?*Output = @ptrCast(@alignCast(c.g_task_propagate_pointer(@ptrCast(result), null)));
        if (output) |out| {
            defer a.destroy(out);
            if (self.cached) |old| a.free(old);
            self.cached = out.bytes;
            if (!self.owner.dead) self.publish(kinds[self.index]);
        }
        self.busy = false;
    }
};
const Output = struct { bytes: [:0]u8 };
