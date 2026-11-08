//! Session-owned device connections shared by panel indicators and controls.
const std = @import("std");
const audio = @import("desktop-audio.zig");
const battery = @import("desktop-battery.zig");
const network = @import("desktop-network.zig");
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
pub const Event = enum { audio, battery, network };
pub const Subscriber = struct {
    context: ?*anyopaque,
    changed: *const fn (?*anyopaque, *Service, Event) void,
};
pub const Service = struct {
    audio_service: ?*audio.Service = null,
    battery_service: ?*battery.Service = null,
    network_client: ?*network.Client = null,
    battery_state: battery.State = .{},
    subscribers: std.ArrayList(*Subscriber) = .empty,

    pub fn create() !*Service {
        const self = try a.create(Service);
        self.* = .{};
        self.audio_service = audio.Service.create(&audioChanged, self) catch null;
        self.battery_service = battery.Service.create(&batteryChanged, self) catch null;
        self.network_client = network.Client.create(&networkChanged, self) catch null;
        return self;
    }
    pub fn destroy(self: *Service) void {
        std.debug.assert(self.subscribers.items.len == 0);
        if (self.audio_service) |service| service.destroy();
        if (self.battery_service) |service| service.destroy();
        if (self.network_client) |client| client.destroy();
        self.subscribers.deinit(a);
        a.destroy(self);
    }
    pub fn subscribe(self: *Service, subscriber: *Subscriber) void {
        self.subscribers.append(a, subscriber) catch @panic("out of memory");
        for (std.enums.values(Event)) |event| subscriber.changed(subscriber.context, self, event);
    }
    pub fn unsubscribe(self: *Service, subscriber: *Subscriber) void {
        for (self.subscribers.items, 0..) |entry, i| if (entry == subscriber) {
            _ = self.subscribers.orderedRemove(i);
            return;
        };
    }
    fn notify(self: *Service, event: Event) void {
        var i: usize = 0;
        while (i < self.subscribers.items.len) {
            const subscriber = self.subscribers.items[i];
            subscriber.changed(subscriber.context, self, event);
            if (i < self.subscribers.items.len and self.subscribers.items[i] == subscriber) i += 1;
        }
    }
    fn audioChanged(ptr: ?*anyopaque, _: *audio.Service) void {
        const self: *Service = @ptrCast(@alignCast(ptr));
        self.notify(.audio);
    }
    fn batteryChanged(ptr: ?*anyopaque, state: battery.State) void {
        const self: *Service = @ptrCast(@alignCast(ptr));
        self.battery_state = state;
        self.notify(.battery);
    }
    fn networkChanged(ptr: ?*anyopaque, _: *network.Client) void {
        const self: *Service = @ptrCast(@alignCast(ptr));
        self.notify(.network);
    }
};

test "device subscribers receive initial state and detach before destruction" {
    const Observer = struct {
        events: [3]usize = @splat(0),
        detach: bool = false,
        subscription: Subscriber = undefined,
        fn changed(ptr: ?*anyopaque, service: *Service, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.events[@backingInt(event)] += 1;
            if (self.detach) service.unsubscribe(&self.subscription);
        }
    };
    const service = try a.create(Service);
    service.* = .{};
    defer service.destroy();
    var first: Observer = .{};
    var second: Observer = .{};
    first.subscription = .{ .context = &first, .changed = &Observer.changed };
    second.subscription = .{ .context = &second, .changed = &Observer.changed };
    service.subscribe(&first.subscription);
    service.subscribe(&second.subscription);
    try std.testing.expectEqual([3]usize{ 1, 1, 1 }, first.events);
    first.detach = true;
    service.notify(.audio);
    service.notify(.audio);
    try std.testing.expectEqual([3]usize{ 2, 1, 1 }, first.events);
    try std.testing.expectEqual([3]usize{ 3, 1, 1 }, second.events);
    service.unsubscribe(&second.subscription);
}
