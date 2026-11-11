//! Bounded asynchronous text clipboard for the desktop's data-control protocol.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const libc = @import("desktop-libc.zig");
const p = @import("desktop-protocols.zig");
const input = @import("desktop-input.zig");
const a = std.heap.page_allocator;
const cast = c.__zig.cast;
const Proxy = c.wl_proxy;
const capacity = 4096;
const utf8: [:0]const u8 = "text/plain;charset=utf-8";
pub const Callback = *const fn (?*anyopaque, ?[]const u8) void;
fn send(proxy: *Proxy, opcode: u32, args: anytype) void {
    _ = @call(.auto, c.wl_proxy_marshal_flags, .{ proxy, opcode, @as([*c]const c.wl_interface, null), c.wl_proxy_get_version(proxy), @as(u32, 0) } ++ args);
}
fn destroyProxy(proxy: *Proxy, opcode: u32) void {
    _ = c.wl_proxy_marshal_flags(proxy, opcode, null, c.wl_proxy_get_version(proxy), 1);
}
fn listen(proxy: *Proxy, listener: anytype, context: anytype) void {
    if (c.wl_proxy_add_listener(proxy, @ptrCast(@constCast(listener)), context) != 0) @panic("clipboard listener");
}
pub const Device = struct {
    seat: *input.Seat,
    proxy: *Proxy,
    offers: std.ArrayList(*Offer) = .empty,
    selection: ?*Offer = null,
    source: ?*Source = null,
    requests: std.ArrayList(*Request) = .empty,
    stopped: bool = false,
    pub fn create(seat: *input.Seat, manager: *Proxy) !*Device {
        const self = try a.create(Device);
        errdefer a.destroy(self);
        const proxy = c.wl_proxy_marshal_flags(manager, 1, &p.zwlr_data_control_device_v1_interface, 1, 0, @as(?*anyopaque, null), seat.proxy) orelse return error.Clipboard;
        self.* = .{ .seat = seat, .proxy = proxy };
        listen(proxy, &listener, self);
        return self;
    }
    pub fn destroy(self: *Device) void {
        while (self.requests.items.len != 0) self.requests.items[0].finish(null);
        self.requests.deinit(a);
        for (self.offers.items) |offer| offer.destroy();
        self.offers.deinit(a);
        if (self.source) |source| source.destroy();
        destroyProxy(self.proxy, 1);
        a.destroy(self);
    }
    pub fn copy(self: *Device, value: []const u8) void {
        if (self.stopped or value.len > capacity) return;
        const manager = self.seat.client.clipboard_manager orelse return;
        const source = a.create(Source) catch return;
        const text = a.dupe(u8, value) catch {
            a.destroy(source);
            return;
        };
        const proxy = c.wl_proxy_marshal_flags(manager, 0, &p.zwlr_data_control_source_v1_interface, 1, 0, @as(?*anyopaque, null)) orelse {
            a.free(text);
            a.destroy(source);
            return;
        };
        source.* = .{ .device = self, .proxy = proxy, .text = text };
        listen(proxy, &Source.listener, source);
        send(proxy, 0, .{utf8.ptr});
        send(proxy, 0, .{@as([*:0]const u8, "text/plain")});
        if (self.source) |previous| previous.destroy();
        self.source = source;
        send(self.proxy, 0, .{proxy});
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
        const request = a.create(Request) catch {
            _ = libc.close(fds[0]);
            _ = libc.close(fds[1]);
            callback(context, null);
            return;
        };
        request.* = .{ .device = self, .fd = fds[0], .callback = callback, .context = context };
        self.requests.append(a, request) catch {
            _ = libc.close(fds[0]);
            _ = libc.close(fds[1]);
            a.destroy(request);
            callback(context, null);
            return;
        };
        send(offer.proxy, 0, .{ mime.ptr, fds[1] });
        _ = libc.close(fds[1]);
        request.source = c.g_unix_fd_add(fds[0], c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR, &Request.read, request);
        request.timer = c.g_timeout_add(5000, &Request.timeout, request);
        self.seat.client.flush();
    }
    fn offered(ptr: ?*anyopaque, _: *Proxy, proxy: *Proxy) callconv(.c) void {
        const self = cast(Device, ptr);
        const offer = a.create(Offer) catch @panic("clipboard offer");
        offer.* = .{ .proxy = proxy };
        self.offers.append(a, offer) catch @panic("clipboard offer");
        listen(proxy, &Offer.listener, offer);
    }
    fn selected(ptr: ?*anyopaque, _: *Proxy, proxy: ?*Proxy) callconv(.c) void {
        const self = cast(Device, ptr);
        self.selection = null;
        var index: usize = 0;
        while (index < self.offers.items.len) {
            const offer = self.offers.items[index];
            if (offer.proxy == proxy) {
                self.selection = offer;
                index += 1;
            } else {
                _ = self.offers.orderedRemove(index);
                offer.destroy();
            }
        }
    }
    fn finished(ptr: ?*anyopaque, _: *Proxy) callconv(.c) void {
        const self = cast(Device, ptr);
        self.stopped = true;
        while (self.requests.items.len != 0) self.requests.items[0].finish(null);
    }
    const listener = extern struct {
        offer: *const @TypeOf(offered) = &offered,
        selection: *const @TypeOf(selected) = &selected,
        finished: *const @TypeOf(finished) = &finished,
    }{};
};
const Offer = struct {
    proxy: *Proxy,
    mime: ?[:0]const u8 = null,
    fn offered(ptr: ?*anyopaque, _: *Proxy, mime: [*c]const u8) callconv(.c) void {
        const self = cast(Offer, ptr);
        const value = std.mem.span(mime);
        if (std.mem.eql(u8, value, utf8)) self.mime = utf8 else if (self.mime == null and (std.mem.eql(u8, value, "text/plain") or std.mem.eql(u8, value, "UTF8_STRING"))) self.mime = if (std.mem.eql(u8, value, "UTF8_STRING")) "UTF8_STRING" else "text/plain";
    }
    const listener = extern struct { offer: *const @TypeOf(offered) = &offered }{};
    fn destroy(self: *Offer) void {
        destroyProxy(self.proxy, 1);
        a.destroy(self);
    }
};
const Source = struct {
    device: *Device,
    proxy: *Proxy,
    text: []u8,
    fn write(ptr: ?*anyopaque, _: *Proxy, _: [*c]const u8, fd: c_int) callconv(.c) void {
        const self = cast(Source, ptr);
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
    fn cancelled(ptr: ?*anyopaque, _: *Proxy) callconv(.c) void {
        const self = cast(Source, ptr);
        if (self.device.source == self) self.device.source = null;
        self.destroy();
    }
    const listener = extern struct { send: *const @TypeOf(write) = &write, cancelled: *const @TypeOf(cancelled) = &cancelled }{};
    fn destroy(self: *Source) void {
        destroyProxy(self.proxy, 1);
        a.free(self.text);
        a.destroy(self);
    }
};
const Request = struct {
    device: *Device,
    fd: c_int,
    callback: Callback,
    context: ?*anyopaque,
    bytes: [capacity + 1]u8 = @splat(0),
    len: usize = 0,
    source: c.guint = 0,
    timer: c.guint = 0,
    fn read(fd: c_int, condition: c.GIOCondition, ptr: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Request, ptr);
        while (true) {
            const n = libc.read(fd, self.bytes[self.len..].ptr, self.bytes.len - self.len);
            if (n < 0) {
                const err = libc.__errno_location().*;
                if (err == libc.EINTR) continue;
                if (err == @backingInt(std.c.E.AGAIN) and condition & c.G_IO_ERR == 0) return 1;
                self.source = 0;
                self.finish(null);
                return 0;
            }
            if (n == 0) {
                self.source = 0;
                self.finish(self.bytes[0..self.len]);
                return 0;
            }
            self.len += @intCast(n);
            if (self.len > capacity) {
                self.source = 0;
                self.finish(null);
                return 0;
            }
        }
    }
    fn timeout(ptr: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Request, ptr);
        self.timer = 0;
        self.finish(null);
        return 0;
    }
    fn finish(self: *Request, value: ?[]const u8) void {
        if (self.source != 0) _ = c.g_source_remove(self.source);
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
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
