//! Explicit requests for the virtual pointer used by headless integration tests.
pub fn Client(comptime c: type, comptime protocols: type) type {
    return struct {
        pub const Manager = opaque {};
        pub const Pointer = opaque {};

        fn request(proxy: *c.wl_proxy, opcode: u32, interface: ?*const c.wl_interface, flags: u32, args: []c.wl_argument) ?*c.wl_proxy {
            return c.wl_proxy_marshal_array_flags(proxy, opcode, interface, c.wl_proxy_get_version(proxy), flags, if (args.len == 0) null else args.ptr);
        }

        pub fn create(manager: *Manager) ?*Pointer {
            const proxy: *c.wl_proxy = @ptrCast(manager);
            var args = [_]c.wl_argument{ .{ .o = null }, .{ .o = null } };
            return @ptrCast(request(proxy, 0, &protocols.zwlr_virtual_pointer_v1_interface, 0, &args));
        }

        pub fn destroyManager(manager: *Manager) void {
            const proxy: *c.wl_proxy = @ptrCast(manager);
            _ = request(proxy, 1, null, 1, &.{});
        }

        pub fn destroy(pointer: *Pointer) void {
            const proxy: *c.wl_proxy = @ptrCast(pointer);
            _ = request(proxy, 8, null, 1, &.{});
        }

        pub fn move(pointer: *Pointer, x: u32, y: u32, width: u32, height: u32) void {
            const proxy: *c.wl_proxy = @ptrCast(pointer);
            var args = [_]c.wl_argument{ .{ .u = 0 }, .{ .u = x }, .{ .u = y }, .{ .u = width }, .{ .u = height } };
            _ = request(proxy, 1, null, 0, &args);
        }

        pub fn relative(pointer: *Pointer, dx: i32, dy: i32, time: u32) void {
            const proxy: *c.wl_proxy = @ptrCast(pointer);
            var args = [_]c.wl_argument{ .{ .u = time }, .{ .f = dx * 256 }, .{ .f = dy * 256 } };
            _ = request(proxy, 0, null, 0, &args);
        }

        pub fn button(pointer: *Pointer, code: u32, state: u32) void {
            const proxy: *c.wl_proxy = @ptrCast(pointer);
            var args = [_]c.wl_argument{ .{ .u = 0 }, .{ .u = code }, .{ .u = state } };
            _ = request(proxy, 2, null, 0, &args);
        }

        pub fn frame(pointer: *Pointer) void {
            const proxy: *c.wl_proxy = @ptrCast(pointer);
            _ = request(proxy, 4, null, 0, &.{});
        }
    };
}
