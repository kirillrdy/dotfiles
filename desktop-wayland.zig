//! Wayland client ABI and core protocol wrappers, independent of GTK.
pub const wl_surface = opaque {};

pub const struct_wl_interface = extern struct {
    name: [*c]const u8 = null,
    version: c_int = 0,
    method_count: c_int = 0,
    methods: [*c]const struct_wl_message = null,
    event_count: c_int = 0,
    events: [*c]const struct_wl_message = null,
};

pub const struct_wl_message = extern struct {
    name: [*c]const u8 = null,
    signature: [*c]const u8 = null,
    types: [*c][*c]const struct_wl_interface = null,
};

pub const struct_wl_array = extern struct {
    size: usize = 0,
    alloc: usize = 0,
    data: ?*anyopaque = null,
};

pub const struct_wl_proxy = opaque {};

pub const wl_proxy = struct_wl_proxy;

pub const wl_interface = struct_wl_interface;

pub const struct_wl_display = opaque {};

pub extern fn wl_proxy_marshal_flags(proxy: ?*struct_wl_proxy, opcode: u32, interface: [*c]const struct_wl_interface, version: u32, flags: u32, ...) ?*struct_wl_proxy;

pub extern fn wl_proxy_destroy(proxy: ?*struct_wl_proxy) void;

pub extern fn wl_proxy_add_listener(proxy: ?*struct_wl_proxy, implementation: [*c]?*const fn () callconv(.c) void, data: ?*anyopaque) c_int;

pub extern fn wl_proxy_get_version(proxy: ?*struct_wl_proxy) u32;

pub const wl_object = opaque {};

pub const wl_argument = extern union {
    i: i32,
    u: u32,
    f: i32,
    s: [*c]const u8,
    o: ?*wl_object,
    n: u32,
    a: [*c]wl_array,
    h: i32,
};

pub extern fn wl_proxy_marshal_array_flags(proxy: ?*struct_wl_proxy, opcode: u32, interface: [*c]const struct_wl_interface, version: u32, flags: u32, args: [*c]wl_argument) ?*struct_wl_proxy;

pub extern fn wl_display_connect(name: [*c]const u8) ?*struct_wl_display;

pub extern fn wl_display_disconnect(display: ?*struct_wl_display) void;

pub extern fn wl_display_get_fd(display: ?*struct_wl_display) c_int;

pub extern fn wl_display_dispatch(display: ?*struct_wl_display) c_int;

pub extern fn wl_display_dispatch_pending(display: ?*struct_wl_display) c_int;

pub extern fn wl_display_prepare_read(display: ?*struct_wl_display) c_int;

pub extern fn wl_display_cancel_read(display: ?*struct_wl_display) void;

pub extern fn wl_display_read_events(display: ?*struct_wl_display) c_int;

pub extern fn wl_display_flush(display: ?*struct_wl_display) c_int;

pub extern fn wl_display_roundtrip(display: ?*struct_wl_display) c_int;

pub const struct_wl_buffer = opaque {};

pub const struct_wl_output = opaque {};

pub const struct_wl_registry = opaque {};

pub const struct_wl_seat = opaque {};

pub const struct_wl_shm = opaque {};

pub const struct_wl_shm_pool = opaque {};

pub extern const wl_registry_interface: struct_wl_interface;

pub extern const wl_shm_pool_interface: struct_wl_interface;

pub extern const wl_shm_interface: struct_wl_interface;

pub extern const wl_buffer_interface: struct_wl_interface;

pub extern const wl_seat_interface: struct_wl_interface;

pub extern const wl_output_interface: struct_wl_interface;

pub fn wl_display_get_registry(wl_display_1: ?*struct_wl_display) callconv(.c) ?*struct_wl_registry {
    const registry = wl_proxy_marshal_flags(@ptrCast(@alignCast(wl_display_1)), WL_DISPLAY_GET_REGISTRY, &wl_registry_interface, wl_proxy_get_version(@ptrCast(@alignCast(wl_display_1))), 0, @as(?*anyopaque, null));
    return @ptrCast(@alignCast(registry));
}

pub const struct_wl_registry_listener = extern struct {
    global: ?*const fn (data: ?*anyopaque, wl_registry: ?*struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void = null,
    global_remove: ?*const fn (data: ?*anyopaque, wl_registry: ?*struct_wl_registry, name: u32) callconv(.c) void = null,
};

pub fn wl_registry_add_listener(wl_registry_1: ?*struct_wl_registry, listener: [*c]const struct_wl_registry_listener, data: ?*anyopaque) callconv(.c) c_int {
    return wl_proxy_add_listener(@ptrCast(@alignCast(wl_registry_1)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn wl_registry_destroy(wl_registry_1: ?*struct_wl_registry) callconv(.c) void {
    wl_proxy_destroy(@ptrCast(@alignCast(wl_registry_1)));
}

pub fn wl_registry_bind(wl_registry_1: ?*struct_wl_registry, name: u32, interface: [*c]const struct_wl_interface, version: u32) callconv(.c) ?*anyopaque {
    const id = wl_proxy_marshal_flags(@ptrCast(@alignCast(wl_registry_1)), WL_REGISTRY_BIND, interface, version, 0, name, interface.*.name, version, @as(?*anyopaque, null));
    return @ptrCast(@alignCast(id));
}

pub fn wl_shm_pool_create_buffer(wl_shm_pool_1: ?*struct_wl_shm_pool, offset: i32, width: i32, height: i32, stride: i32, format: u32) callconv(.c) ?*struct_wl_buffer {
    const id = wl_proxy_marshal_flags(@ptrCast(@alignCast(wl_shm_pool_1)), WL_SHM_POOL_CREATE_BUFFER, &wl_buffer_interface, wl_proxy_get_version(@ptrCast(@alignCast(wl_shm_pool_1))), 0, @as(?*anyopaque, null), offset, width, height, stride, format);
    return @ptrCast(@alignCast(id));
}

pub fn wl_shm_pool_destroy(wl_shm_pool_1: ?*struct_wl_shm_pool) callconv(.c) void {
    _ = wl_proxy_marshal_flags(@ptrCast(@alignCast(wl_shm_pool_1)), WL_SHM_POOL_DESTROY, null, wl_proxy_get_version(@ptrCast(@alignCast(wl_shm_pool_1))), 1);
}

pub const WL_SHM_FORMAT_ARGB8888: c_int = 0;

pub const WL_SHM_FORMAT_XRGB8888: c_int = 1;

pub const WL_SHM_FORMAT_XBGR8888: c_int = 875709016;

pub const WL_SHM_FORMAT_ABGR8888: c_int = 875708993;
pub const WL_SHM_FORMAT_BGR888: c_int = 0x34324742;

pub fn wl_shm_destroy(wl_shm_1: ?*struct_wl_shm) callconv(.c) void {
    wl_proxy_destroy(@ptrCast(@alignCast(wl_shm_1)));
}

pub fn wl_shm_create_pool(wl_shm_1: ?*struct_wl_shm, fd: i32, size: i32) callconv(.c) ?*struct_wl_shm_pool {
    const id = wl_proxy_marshal_flags(@ptrCast(@alignCast(wl_shm_1)), WL_SHM_CREATE_POOL, &wl_shm_pool_interface, wl_proxy_get_version(@ptrCast(@alignCast(wl_shm_1))), 0, @as(?*anyopaque, null), fd, size);
    return @ptrCast(@alignCast(id));
}

pub fn wl_buffer_destroy(wl_buffer_1: ?*struct_wl_buffer) callconv(.c) void {
    _ = wl_proxy_marshal_flags(@ptrCast(@alignCast(wl_buffer_1)), WL_BUFFER_DESTROY, null, wl_proxy_get_version(@ptrCast(@alignCast(wl_buffer_1))), 1);
}

pub fn wl_seat_destroy(wl_seat_1: ?*struct_wl_seat) callconv(.c) void {
    wl_proxy_destroy(@ptrCast(@alignCast(wl_seat_1)));
}

pub const WL_OUTPUT_MODE_CURRENT: c_int = 1;

pub const struct_wl_output_listener = extern struct {
    geometry: ?*const fn (data: ?*anyopaque, wl_output: ?*struct_wl_output, x: i32, y: i32, physical_width: i32, physical_height: i32, subpixel: i32, make: [*c]const u8, model: [*c]const u8, transform: i32) callconv(.c) void = null,
    mode: ?*const fn (data: ?*anyopaque, wl_output: ?*struct_wl_output, flags: u32, width: i32, height: i32, refresh: i32) callconv(.c) void = null,
    done: ?*const fn (data: ?*anyopaque, wl_output: ?*struct_wl_output) callconv(.c) void = null,
    scale: ?*const fn (data: ?*anyopaque, wl_output: ?*struct_wl_output, factor: i32) callconv(.c) void = null,
    name: ?*const fn (data: ?*anyopaque, wl_output: ?*struct_wl_output, name: [*c]const u8) callconv(.c) void = null,
    description: ?*const fn (data: ?*anyopaque, wl_output: ?*struct_wl_output, description: [*c]const u8) callconv(.c) void = null,
};

pub fn wl_output_add_listener(wl_output_1: ?*struct_wl_output, listener: [*c]const struct_wl_output_listener, data: ?*anyopaque) callconv(.c) c_int {
    return wl_proxy_add_listener(@ptrCast(@alignCast(wl_output_1)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn wl_output_destroy(wl_output_1: ?*struct_wl_output) callconv(.c) void {
    wl_proxy_destroy(@ptrCast(@alignCast(wl_output_1)));
}

pub const WL_DISPLAY_GET_REGISTRY = @as(c_int, 1);

pub const WL_REGISTRY_BIND = @as(c_int, 0);

pub const WL_SHM_POOL_CREATE_BUFFER = @as(c_int, 0);

pub const WL_SHM_POOL_DESTROY = @as(c_int, 1);

pub const WL_SHM_CREATE_POOL = @as(c_int, 0);

pub const WL_BUFFER_DESTROY = @as(c_int, 0);

pub const wl_array = struct_wl_array;

pub const wl_display = struct_wl_display;

pub const wl_buffer = struct_wl_buffer;

pub const wl_output = struct_wl_output;

pub const wl_registry = struct_wl_registry;

pub const wl_seat = struct_wl_seat;

pub const wl_shm = struct_wl_shm;

pub const wl_registry_listener = struct_wl_registry_listener;

pub const wl_output_listener = struct_wl_output_listener;
