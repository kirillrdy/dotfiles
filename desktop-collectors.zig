//! Shared collectors: blocking device/API queries run in GLib workers, never GTK.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const data = @import("desktop-panel-data.zig");
const u = @import("desktop-util.zig");
const devices = @import("desktop-devices.zig");
const battery = @import("desktop-battery.zig");
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
    devices: *devices.Service,
    subscription: devices.Subscriber = undefined,
    battery_alerts: battery.Alerts = .{},

    pub fn start(self: *Service) void {
        for (&self.sources, 0..) |*source, i| source.* = .{ .owner = self, .index = i };
        self.subscription = .{ .context = self, .changed = &deviceChanged };
        self.devices.subscribe(&self.subscription);
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

    fn deviceChanged(ptr: ?*anyopaque, service: *devices.Service, event: devices.Event) void {
        const self: *Service = @ptrCast(@alignCast(ptr));
        if (self.dead) return;
        if (event == .battery) if (self.battery_alerts.update(service.battery_state)) |level| battery.notifyWarning(level);
        self.sources[1].publish("status");
    }
    pub fn deinit(self: *Service) void {
        self.dead = true;
        self.devices.unsubscribe(&self.subscription);
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        for (&self.sources) |*source| {
            while (source.busy) _ = c.g_main_context_iteration(null, 1);
            if (source.cached) |output| output.destroy();
        }
    }
};
const Source = struct {
    owner: *Service,
    index: usize,
    remaining: u32 = 0,
    busy: bool = false,
    cached: ?*Output = null,
    monitor: ?data.Monitor = null, // Accessed only by this source's worker.

    fn publish(self: *Source, kind: []const u8) void {
        const output = self.cached orelse return;
        var update = output.value;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        if (self.index == 1 and !std.mem.eql(u8, u.env("WB_PANEL_DEMO") orelse "", "1")) {
            if (self.owner.devices.network_client) |client| data.addNetwork(alloc, &update, client.state()) catch return;
            data.addAudio(alloc, &update, if (self.owner.devices.audio_service) |service| service.state(.output) else null, if (self.owner.devices.audio_service) |service| service.state(.input) else null) catch return;
            data.addBattery(alloc, &update, self.owner.devices.battery_state) catch return;
        }
        self.owner.panel.update(kind, update);
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
        const output = a.create(Output) catch {
            c.g_task_return_pointer(task, null, null);
            return;
        };
        output.* = .{ .arena = std.heap.ArenaAllocator.init(a), .value = undefined };
        const alloc = output.arena.allocator();
        const demo = std.mem.eql(u8, u.env("WB_PANEL_DEMO") orelse "", "1");
        const result = blk: {
            if (self.index == 0) {
                if (self.monitor == null) self.monitor = data.Monitor.init(alloc) catch break :blk null;
                break :blk self.monitor.?.sample(alloc, demo) catch null;
            }
            break :blk data.sample(alloc, kinds[self.index], self.owner.icon, demo) catch null;
        };
        // Transfer the arena and its typed update to the main thread.
        if (result) |value| {
            output.value = value;
            c.g_task_return_pointer(task, output, null);
        } else {
            output.destroy();
            c.g_task_return_pointer(task, null, null);
        }
    }

    fn done(_: ?*c.GObject, result: ?*c.GAsyncResult, ptr: c.gpointer) callconv(.c) void {
        const self: *Source = @ptrCast(@alignCast(ptr));
        const output: ?*Output = @ptrCast(@alignCast(c.g_task_propagate_pointer(@ptrCast(result), null)));
        if (output) |out| {
            if (self.cached) |old| old.destroy();
            self.cached = out;
            if (!self.owner.dead) self.publish(kinds[self.index]);
        }
        self.busy = false;
    }
};
const Output = struct {
    arena: std.heap.ArenaAllocator,
    value: data.Update,
    fn destroy(self: *Output) void {
        self.arena.deinit();
        a.destroy(self);
    }
};
