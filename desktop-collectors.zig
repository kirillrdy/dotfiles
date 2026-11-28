//! Shared collectors: blocking device/API queries run in GLib workers, never the UI thread.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const data = @import("desktop-panel-data.zig");
const u = @import("desktop-util.zig");
const devices = @import("desktop-devices.zig");
const battery = @import("desktop-battery.zig");
const panel = @import("desktop-panel.zig");
const kinds = [_][]const u8{ "monitors", "status", "disk", "codex", "claude", "antigravity" };
const intervals = [_]u32{ 1, 10, 10, 240, 240, 240 }; // Half-second ticks.

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    panel: *panel.Service,
    sources: [kinds.len]Source = undefined,
    timer: u32 = 0,
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
        self.timer = mainloop.timeout(500, self, tick);
    }

    pub fn refresh(self: *Service, kind: []const u8) void {
        if (self.dead) return;
        for (&self.sources, kinds) |*source, name| if (std.mem.eql(u8, kind, name)) {
            source.remaining = 0;
            if (!source.busy) source.launch();
        };
    }

    fn tick(self: *Service) bool {
        const revision = self.panel.revision();
        for (&self.sources, kinds) |*source, kind| {
            // Initialize new panels without repeatedly repainting unchanged data.
            if (revision != self.revision) if (source.cached != null) source.publish(kind);
            if (source.remaining > 0) source.remaining -= 1;
            if (source.remaining == 0 and !source.busy) source.launch();
        }
        self.revision = revision;
        return true;
    }

    fn deviceChanged(ptr: ?*anyopaque, service: *devices.Service, event: devices.Event) void {
        const self: *Service = @ptrCast(@alignCast(ptr));
        if (self.dead) return;
        if (event == .battery) if (self.battery_alerts.update(service.battery_state)) |level| battery.notifyWarning(self.allocator, level);
        self.sources[1].publish("status");
    }
    pub fn deinit(self: *Service) void {
        self.dead = true;
        self.devices.unsubscribe(&self.subscription);
        if (self.timer != 0) _ = mainloop.remove(self.timer);
        for (&self.sources) |*source| {
            while (source.busy) _ = mainloop.iteration(true);
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
        var arena = std.heap.ArenaAllocator.init(self.owner.allocator);
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
        mainloop.background(self, work, done);
    }

    fn work(self: *Source) ?*Output {
        const output = self.owner.allocator.create(Output) catch return null;
        output.* = .{ .allocator = self.owner.allocator, .arena = std.heap.ArenaAllocator.init(self.owner.allocator), .value = undefined };
        const alloc = output.arena.allocator();
        const demo = std.mem.eql(u8, u.env("WB_PANEL_DEMO") orelse "", "1");
        const result = blk: {
            if (self.index == 0) {
                if (self.monitor == null) self.monitor = data.Monitor.init(alloc, self.owner.io) catch break :blk null;
                break :blk self.monitor.?.sample(alloc, self.owner.io, demo) catch null;
            }
            break :blk data.sample(alloc, self.owner.io, kinds[self.index], demo) catch null;
        };
        // Transfer the arena and its typed update to the main thread.
        if (result) |value| {
            output.value = value;
            return output;
        }
        output.destroy();
        return null;
    }

    fn done(self: *Source, output: ?*Output) void {
        if (output) |out| {
            if (self.cached) |old| old.destroy();
            self.cached = out;
            if (!self.owner.dead) self.publish(kinds[self.index]);
        }
        self.busy = false;
    }
};
const Output = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    value: data.Update,
    fn destroy(self: *Output) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};
