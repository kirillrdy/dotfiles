//! Test transport: capture typed Wayland requests without a compositor.
const c = @import("../desktop-gtk.zig");
pub const wl_proxy = c.wl_proxy;
pub const wl_interface = c.wl_interface;
pub const wl_argument = c.wl_argument;
pub var opcode: u32 = 0;
pub var flags: u32 = 0;
pub var version: u32 = 0;
pub var interface: ?*const wl_interface = null;
pub var arguments: [5]wl_argument = undefined;
pub var empty: bool = false;

pub fn wl_proxy_get_version(_: ?*wl_proxy) u32 {
    return 2;
}
pub fn wl_proxy_marshal_array_flags(_: ?*wl_proxy, request: u32, iface: ?*const wl_interface, request_version: u32, request_flags: u32, args: [*c]wl_argument) ?*wl_proxy {
    opcode = request;
    flags = request_flags;
    version = request_version;
    interface = iface;
    empty = args == null;
    const count: usize = if (request_flags == 1 or request == 4) 0 else if (iface != null) 2 else if (request == 1) 5 else 3;
    for (0..count) |i| arguments[i] = args[i];
    return @ptrFromInt(0x1000);
}
