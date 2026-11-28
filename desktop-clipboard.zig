//! Bounded asynchronous text clipboard for the desktop's data-control protocol.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const libc = @import("desktop-libc.zig");
const wl = @import("wayland-client");
const input = @import("desktop-input.zig");
fn cast(comptime T: type, ptr: anytype) *T { return @ptrCast(@alignCast(ptr)); }
const capacity = 4096;
const utf8: [:0]const u8 = "text/plain;charset=utf-8";
pub const Callback = *const fn (?*anyopaque, ?[]const u8) void;
pub const Device = struct {
    seat: *input.Seat,
    proxy: wl.zwlr_data_control_device_v1,
    offers: std.ArrayList(*Offer) = .empty,
    selection: ?*Offer = null,
    source: ?*Source = null,
    requests: std.ArrayList(*Request) = .empty,
    stopped: bool = false,
    pub fn create(seat: *input.Seat, manager: wl.zwlr_data_control_manager_v1) !*Device {
        const self = try seat.client.allocator.create(Device);
        self.* = .{ .seat = seat, .proxy = manager.get_data_device(seat.proxy) };
        self.proxy.listen(Device, self, deviceEvent);
        return self;
    }
    pub fn destroy(self: *Device) void {
        while (self.requests.items.len != 0) self.requests.items[0].finish(null);
        self.requests.deinit(self.seat.client.allocator);
        for (self.offers.items) |offer| offer.destroy();
        self.offers.deinit(self.seat.client.allocator);
        if (self.source) |source| source.destroy();
        self.proxy.destroy();
        self.seat.client.allocator.destroy(self);
    }
    pub fn copy(self: *Device, value: []const u8) void {
        if (self.stopped or value.len > capacity) return;
        const manager = self.seat.client.clipboard_manager orelse return;
        const source = self.seat.client.allocator.create(Source) catch return;
        const text = self.seat.client.allocator.dupe(u8, value) catch {
            self.seat.client.allocator.destroy(source);
            return;
        };
        source.* = .{ .device = self, .proxy = manager.create_data_source(), .text = text };
        source.proxy.listen(Source, source, Source.sourceEvent);
        source.proxy.offer(utf8);
        source.proxy.offer("text/plain");
        if (self.source) |previous| previous.destroy();
        self.source = source;
        self.proxy.set_selection(source.proxy);
        self.seat.client.flush();
    }
    pub fn paste(self: *Device, callback: Callback, context: ?*anyopaque) void {
        if (self.stopped) {
            callback(context, null);
            return;
        }
        if (self.source) |source| {
            callback(context, source.text);
            return;
        }
        const offer = self.selection orelse {
            callback(context, null);
            return;
        };
        const mime = offer.mime orelse {
            callback(context, null);
            return;
        };
        var fds: [2]c_int = undefined;
        if (libc.pipe2(&fds, libc.O_CLOEXEC | libc.O_NONBLOCK) != 0) {
            callback(context, null);
            return;
        }
        const request = self.seat.client.allocator.create(Request) catch {
            _ = libc.close(fds[0]);
            _ = libc.close(fds[1]);
            callback(context, null);
            return;
        };
        request.* = .{ .device = self, .fd = fds[0], .callback = callback, .context = context };
        self.requests.append(self.seat.client.allocator, request) catch {
            _ = libc.close(fds[0]);
            _ = libc.close(fds[1]);
            self.seat.client.allocator.destroy(request);
            callback(context, null);
            return;
        };
        offer.proxy.receive(mime, fds[1]);
        _ = libc.close(fds[1]);
        request.source = mainloop.watch(self.seat.client.io, fds[0], mainloop.IN | mainloop.HUP | mainloop.ERR, request, Request.read);
        request.timer = mainloop.timeout(self.seat.client.io, 5000, request, Request.timeout);
        self.seat.client.flush();
    }
    fn deviceEvent(self: *Device, _: wl.zwlr_data_control_device_v1, event: wl.zwlr_data_control_device_v1.Event) void {
        switch (event) {
            .data_offer => |value| {
                const offer = self.seat.client.allocator.create(Offer) catch @panic("clipboard offer");
                offer.* = .{ .allocator = self.seat.client.allocator, .proxy = value.id };
                self.offers.append(self.seat.client.allocator, offer) catch @panic("clipboard offer");
                value.id.listen(Offer, offer, Offer.offerEvent);
            },
            .selection => |value| {
                self.selection = null;
                var index: usize = 0;
                while (index < self.offers.items.len) {
                    const offer = self.offers.items[index];
                    if (@import("desktop-surface.zig").same(@as(?wl.zwlr_data_control_offer_v1, offer.proxy), value.id)) {
                        self.selection = offer;
                        index += 1;
                    } else {
                        _ = self.offers.orderedRemove(index);
                        offer.destroy();
                    }
                }
            },
            .finished => {
                self.stopped = true;
                while (self.requests.items.len != 0) self.requests.items[0].finish(null);
            },
            // Primary selection offers are not tracked; destroy them so they do not leak.
            .primary_selection => |value| if (value.id) |offer| {
                for (self.offers.items, 0..) |entry, index| if (entry.proxy.proxy.id == offer.proxy.id) {
                    _ = self.offers.orderedRemove(index);
                    entry.destroy();
                    break;
                };
            },
        }
    }
};
const Offer = struct {
    allocator: std.mem.Allocator,
    proxy: wl.zwlr_data_control_offer_v1,
    mime: ?[:0]const u8 = null,
    fn offerEvent(self: *Offer, _: wl.zwlr_data_control_offer_v1, event: wl.zwlr_data_control_offer_v1.Event) void {
        const value = event.offer.mime_type;
        if (std.mem.eql(u8, value, utf8)) self.mime = utf8 else if (self.mime == null and (std.mem.eql(u8, value, "text/plain") or std.mem.eql(u8, value, "UTF8_STRING"))) self.mime = if (std.mem.eql(u8, value, "UTF8_STRING")) "UTF8_STRING" else "text/plain";
    }
    fn destroy(self: *Offer) void {
        self.proxy.destroy();
        self.allocator.destroy(self);
    }
};
const Source = struct {
    device: *Device,
    proxy: wl.zwlr_data_control_source_v1,
    text: []u8,
    fn sourceEvent(self: *Source, _: wl.zwlr_data_control_source_v1, event: wl.zwlr_data_control_source_v1.Event) void {
        switch (event) {
            .send => |value| self.write(value.fd),
            .cancelled => {
                if (self.device.source == self) self.device.source = null;
                self.destroy();
            },
        }
    }
    fn write(self: *Source, fd: c_int) void {
        defer _ = libc.close(fd);
        // Text is bounded to PIPE_BUF, so the empty transfer pipe cannot block.
        var offset: usize = 0;
        while (offset < self.text.len) {
            const n = libc.write(fd, self.text.ptr + offset, self.text.len - offset);
            if (n < 0) {
                if (libc.__errno_location().* == libc.EINTR) continue;
                return;
            }
            if (n == 0) return;
            offset += @intCast(n);
        }
    }
    fn destroy(self: *Source) void {
        self.proxy.destroy();
        self.device.seat.client.allocator.free(self.text);
        self.device.seat.client.allocator.destroy(self);
    }
};
const Request = struct {
    device: *Device,
    fd: c_int,
    callback: Callback,
    context: ?*anyopaque,
    bytes: [capacity + 1]u8 = @splat(0),
    len: usize = 0,
    source: u32 = 0,
    timer: u32 = 0,
    fn read(self: *Request, fd: c_int, condition: u32) bool {
        while (true) {
            const n = libc.read(fd, self.bytes[self.len..].ptr, self.bytes.len - self.len);
            if (n < 0) {
                const err = libc.__errno_location().*;
                if (err == libc.EINTR) continue;
                if (err == @backingInt(std.c.E.AGAIN) and condition & mainloop.ERR == 0) return true;
                self.source = 0;
                self.finish(null);
                return false;
            }
            if (n == 0) {
                self.source = 0;
                self.finish(self.bytes[0..self.len]);
                return false;
            }
            self.len += @intCast(n);
            if (self.len > capacity) {
                self.source = 0;
                self.finish(null);
                return false;
            }
        }
    }
    fn timeout(self: *Request) bool {
        self.timer = 0;
        self.finish(null);
        return false;
    }
    fn finish(self: *Request, value: ?[]const u8) void {
        const a = self.device.seat.client.allocator;
        if (self.source != 0) _ = mainloop.remove(self.device.seat.client.io, self.source);
        if (self.timer != 0) _ = mainloop.remove(self.device.seat.client.io, self.timer);
        _ = libc.close(self.fd);
        for (self.device.requests.items, 0..) |request, index| if (request == self) {
            _ = self.device.requests.orderedRemove(index);
            break;
        };
        self.callback(self.context, value);
        std.crypto.secureZero(u8, &self.bytes);
        a.destroy(self);
    }
};
