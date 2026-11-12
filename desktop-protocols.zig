//! Native protocol wrappers over metadata generated from the protocol XML.
const c = @import("desktop-gtk.zig");
pub const Interface = c.struct_wl_interface;
pub extern const xdg_activation_v1_interface: Interface;
pub extern const xdg_activation_token_v1_interface: Interface;
pub extern const zwp_text_input_manager_v3_interface: Interface;
pub extern const zwp_text_input_v3_interface: Interface;
pub extern const wp_cursor_shape_manager_v1_interface: Interface;
pub extern const wp_cursor_shape_device_v1_interface: Interface;
pub extern const zwp_tablet_tool_v2_interface: Interface;
pub extern const zwp_tablet_v2_interface: Interface;
const metadata = @import("protocol-metadata").Metadata(@import("desktop-wayland.zig"));
comptime {
    // Emit canonical exported objects; extern declarations below preserve their identity.
    for (@import("std").meta.declarations(metadata)) |name| _ = &@field(metadata, name);
}

pub extern const zwlr_screencopy_manager_v1_interface: Interface;

pub extern const zwlr_screencopy_frame_v1_interface: Interface;

pub extern const zwlr_data_control_manager_v1_interface: Interface;

pub extern const zwlr_data_control_device_v1_interface: Interface;

pub extern const zwlr_data_control_source_v1_interface: Interface;

pub extern const zwlr_data_control_offer_v1_interface: Interface;

pub extern const ext_foreign_toplevel_list_v1_interface: Interface;

pub extern const ext_foreign_toplevel_handle_v1_interface: Interface;

pub extern const ext_image_capture_source_v1_interface: Interface;

pub extern const ext_output_image_capture_source_manager_v1_interface: Interface;

pub extern const ext_foreign_toplevel_image_capture_source_manager_v1_interface: Interface;

pub extern const ext_image_copy_capture_manager_v1_interface: Interface;

pub extern const ext_image_copy_capture_session_v1_interface: Interface;

pub extern const ext_image_copy_capture_frame_v1_interface: Interface;

pub extern const ext_image_copy_capture_cursor_session_v1_interface: Interface;

pub extern const dotfiles_overview_v1_interface: Interface;

pub extern const zwlr_virtual_pointer_v1_interface: Interface;

pub extern const zwlr_virtual_pointer_manager_v1_interface: Interface;

pub const zwlr_screencopy_frame_v1 = opaque {};

pub const zwlr_screencopy_manager_v1 = opaque {};

pub const zwlr_data_control_device_v1 = opaque {};

pub const zwlr_data_control_manager_v1 = opaque {};

pub const zwlr_data_control_source_v1 = opaque {};

pub const ext_foreign_toplevel_handle_v1 = opaque {};

pub const ext_foreign_toplevel_list_v1 = opaque {};

pub const ext_foreign_toplevel_image_capture_source_manager_v1 = opaque {};

pub const ext_image_capture_source_v1 = opaque {};

pub const ext_image_copy_capture_frame_v1 = opaque {};

pub const ext_image_copy_capture_manager_v1 = opaque {};

pub const ext_image_copy_capture_session_v1 = opaque {};

pub const dotfiles_overview_v1 = opaque {};

pub const ZWLR_SCREENCOPY_MANAGER_V1_CAPTURE_OUTPUT = @as(c_int, 0);

pub const ZWLR_SCREENCOPY_MANAGER_V1_CAPTURE_OUTPUT_REGION = @as(c_int, 1);

pub const ZWLR_SCREENCOPY_MANAGER_V1_DESTROY = @as(c_int, 2);

pub const ZWLR_SCREENCOPY_FRAME_V1_COPY = @as(c_int, 0);

pub const ZWLR_SCREENCOPY_FRAME_V1_DESTROY = @as(c_int, 1);

pub const ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT = @as(c_int, 1);

pub const ZWLR_DATA_CONTROL_MANAGER_V1_CREATE_DATA_SOURCE = @as(c_int, 0);

pub const ZWLR_DATA_CONTROL_MANAGER_V1_GET_DATA_DEVICE = @as(c_int, 1);

pub const ZWLR_DATA_CONTROL_MANAGER_V1_DESTROY = @as(c_int, 2);

pub const ZWLR_DATA_CONTROL_DEVICE_V1_SET_SELECTION = @as(c_int, 0);

pub const ZWLR_DATA_CONTROL_DEVICE_V1_DESTROY = @as(c_int, 1);

pub const ZWLR_DATA_CONTROL_SOURCE_V1_OFFER = @as(c_int, 0);

pub const ZWLR_DATA_CONTROL_SOURCE_V1_DESTROY = @as(c_int, 1);

pub const EXT_FOREIGN_TOPLEVEL_LIST_V1_DESTROY = @as(c_int, 1);

pub const EXT_FOREIGN_TOPLEVEL_HANDLE_V1_DESTROY = @as(c_int, 0);

pub const EXT_IMAGE_CAPTURE_SOURCE_V1_DESTROY = @as(c_int, 0);

pub const EXT_FOREIGN_TOPLEVEL_IMAGE_CAPTURE_SOURCE_MANAGER_V1_CREATE_SOURCE = @as(c_int, 0);

pub const EXT_FOREIGN_TOPLEVEL_IMAGE_CAPTURE_SOURCE_MANAGER_V1_DESTROY = @as(c_int, 1);

pub const EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_CREATE_SESSION = @as(c_int, 0);

pub const EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_DESTROY = @as(c_int, 2);

pub const EXT_IMAGE_COPY_CAPTURE_SESSION_V1_CREATE_FRAME = @as(c_int, 0);

pub const EXT_IMAGE_COPY_CAPTURE_SESSION_V1_DESTROY = @as(c_int, 1);

pub const EXT_IMAGE_COPY_CAPTURE_FRAME_V1_DESTROY = @as(c_int, 0);

pub const EXT_IMAGE_COPY_CAPTURE_FRAME_V1_ATTACH_BUFFER = @as(c_int, 1);

pub const EXT_IMAGE_COPY_CAPTURE_FRAME_V1_DAMAGE_BUFFER = @as(c_int, 2);

pub const EXT_IMAGE_COPY_CAPTURE_FRAME_V1_CAPTURE = @as(c_int, 3);

pub const DOTFILES_OVERVIEW_V1_DESTROY = @as(c_int, 0);

pub const DOTFILES_OVERVIEW_V1_REFRESH = @as(c_int, 1);

pub const DOTFILES_OVERVIEW_V1_ACTIVATE = @as(c_int, 2);

pub const DOTFILES_OVERVIEW_V1_CLOSE = @as(c_int, 3);

pub const DOTFILES_OVERVIEW_V1_SWITCH_WORKSPACE = @as(c_int, 4);

pub const DOTFILES_OVERVIEW_V1_MOVE = @as(c_int, 5);

pub const zwlr_screencopy_frame_v1_listener = extern struct {
    buffer: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1, format: u32, width: u32, height: u32, stride: u32) callconv(.c) void = null,
    flags: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1, flags: u32) callconv(.c) void = null,
    ready: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1, tv_sec_hi: u32, tv_sec_lo: u32, tv_nsec: u32) callconv(.c) void = null,
    failed: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1) callconv(.c) void = null,
    damage: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1, x: u32, y: u32, width: u32, height: u32) callconv(.c) void = null,
    linux_dmabuf: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1, format: u32, width: u32, height: u32) callconv(.c) void = null,
    buffer_done: ?*const fn (data: ?*anyopaque, zwlr_screencopy_frame_v1: ?*zwlr_screencopy_frame_v1) callconv(.c) void = null,
};

pub const zwlr_data_control_source_v1_listener = extern struct {
    send: ?*const fn (data: ?*anyopaque, zwlr_data_control_source_v1: ?*zwlr_data_control_source_v1, mime_type: [*c]const u8, fd: i32) callconv(.c) void = null,
    cancelled: ?*const fn (data: ?*anyopaque, zwlr_data_control_source_v1: ?*zwlr_data_control_source_v1) callconv(.c) void = null,
};

pub const ext_foreign_toplevel_list_v1_listener = extern struct {
    toplevel: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_list_v1: ?*ext_foreign_toplevel_list_v1, toplevel: ?*ext_foreign_toplevel_handle_v1) callconv(.c) void = null,
    finished: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_list_v1: ?*ext_foreign_toplevel_list_v1) callconv(.c) void = null,
};

pub const ext_foreign_toplevel_handle_v1_listener = extern struct {
    closed: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_handle_v1: ?*ext_foreign_toplevel_handle_v1) callconv(.c) void = null,
    done: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_handle_v1: ?*ext_foreign_toplevel_handle_v1) callconv(.c) void = null,
    title: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_handle_v1: ?*ext_foreign_toplevel_handle_v1, title: [*c]const u8) callconv(.c) void = null,
    app_id: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_handle_v1: ?*ext_foreign_toplevel_handle_v1, app_id: [*c]const u8) callconv(.c) void = null,
    identifier: ?*const fn (data: ?*anyopaque, ext_foreign_toplevel_handle_v1: ?*ext_foreign_toplevel_handle_v1, identifier: [*c]const u8) callconv(.c) void = null,
};

pub const ext_image_copy_capture_session_v1_listener = extern struct {
    buffer_size: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_session_v1: ?*ext_image_copy_capture_session_v1, width: u32, height: u32) callconv(.c) void = null,
    shm_format: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_session_v1: ?*ext_image_copy_capture_session_v1, format: u32) callconv(.c) void = null,
    dmabuf_device: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_session_v1: ?*ext_image_copy_capture_session_v1, device: [*c]c.struct_wl_array) callconv(.c) void = null,
    dmabuf_format: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_session_v1: ?*ext_image_copy_capture_session_v1, format: u32, modifiers: [*c]c.struct_wl_array) callconv(.c) void = null,
    done: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_session_v1: ?*ext_image_copy_capture_session_v1) callconv(.c) void = null,
    stopped: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_session_v1: ?*ext_image_copy_capture_session_v1) callconv(.c) void = null,
};

pub const ext_image_copy_capture_frame_v1_listener = extern struct {
    transform: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_frame_v1: ?*ext_image_copy_capture_frame_v1, transform: u32) callconv(.c) void = null,
    damage: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_frame_v1: ?*ext_image_copy_capture_frame_v1, x: i32, y: i32, width: i32, height: i32) callconv(.c) void = null,
    presentation_time: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_frame_v1: ?*ext_image_copy_capture_frame_v1, tv_sec_hi: u32, tv_sec_lo: u32, tv_nsec: u32) callconv(.c) void = null,
    ready: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_frame_v1: ?*ext_image_copy_capture_frame_v1) callconv(.c) void = null,
    failed: ?*const fn (data: ?*anyopaque, ext_image_copy_capture_frame_v1: ?*ext_image_copy_capture_frame_v1, reason: u32) callconv(.c) void = null,
};

pub const dotfiles_overview_v1_listener = extern struct {
    workspace: ?*const fn (data: ?*anyopaque, dotfiles_overview_v1: ?*dotfiles_overview_v1, index: u32, name: [*c]const u8, active: u32) callconv(.c) void = null,
    window: ?*const fn (data: ?*anyopaque, dotfiles_overview_v1: ?*dotfiles_overview_v1, identifier: [*c]const u8, workspace: u32, x: i32, y: i32, width: i32, height: i32, sticky: u32) callconv(.c) void = null,
    done: ?*const fn (data: ?*anyopaque, dotfiles_overview_v1: ?*dotfiles_overview_v1) callconv(.c) void = null,
};

pub fn zwlr_screencopy_manager_v1_capture_output(mgr: ?*zwlr_screencopy_manager_v1, overlay_cursor: i32, output: ?*c.struct_wl_output) callconv(.c) ?*zwlr_screencopy_frame_v1 {
    const frame = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), ZWLR_SCREENCOPY_MANAGER_V1_CAPTURE_OUTPUT, &zwlr_screencopy_frame_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 0, @as(?*anyopaque, null), overlay_cursor, output);
    return @ptrCast(@alignCast(frame));
}

pub fn zwlr_screencopy_manager_v1_capture_output_region(mgr: ?*zwlr_screencopy_manager_v1, overlay_cursor: i32, output: ?*c.struct_wl_output, x: i32, y: i32, width: i32, height: i32) callconv(.c) ?*zwlr_screencopy_frame_v1 {
    const frame = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), ZWLR_SCREENCOPY_MANAGER_V1_CAPTURE_OUTPUT_REGION, &zwlr_screencopy_frame_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 0, @as(?*anyopaque, null), overlay_cursor, output, x, y, width, height);
    return @ptrCast(@alignCast(frame));
}

pub fn zwlr_screencopy_manager_v1_destroy(mgr: ?*zwlr_screencopy_manager_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), ZWLR_SCREENCOPY_MANAGER_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 1);
}

pub fn zwlr_screencopy_frame_v1_add_listener(frame: ?*zwlr_screencopy_frame_v1, listener: [*c]const zwlr_screencopy_frame_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(frame)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn zwlr_screencopy_frame_v1_get_version(frame: ?*zwlr_screencopy_frame_v1) callconv(.c) u32 {
    return c.wl_proxy_get_version(@ptrCast(@alignCast(frame)));
}

pub fn zwlr_screencopy_frame_v1_copy(frame: ?*zwlr_screencopy_frame_v1, buffer: ?*c.struct_wl_buffer) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(frame)), ZWLR_SCREENCOPY_FRAME_V1_COPY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(frame))), 0, buffer);
}

pub fn zwlr_screencopy_frame_v1_destroy(frame: ?*zwlr_screencopy_frame_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(frame)), ZWLR_SCREENCOPY_FRAME_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(frame))), 1);
}

pub fn zwlr_data_control_manager_v1_create_data_source(mgr: ?*zwlr_data_control_manager_v1) callconv(.c) ?*zwlr_data_control_source_v1 {
    const id = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), ZWLR_DATA_CONTROL_MANAGER_V1_CREATE_DATA_SOURCE, &zwlr_data_control_source_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 0, @as(?*anyopaque, null));
    return @ptrCast(@alignCast(id));
}

pub fn zwlr_data_control_manager_v1_get_data_device(mgr: ?*zwlr_data_control_manager_v1, seat: ?*c.struct_wl_seat) callconv(.c) ?*zwlr_data_control_device_v1 {
    const id = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), ZWLR_DATA_CONTROL_MANAGER_V1_GET_DATA_DEVICE, &zwlr_data_control_device_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 0, @as(?*anyopaque, null), seat);
    return @ptrCast(@alignCast(id));
}

pub fn zwlr_data_control_manager_v1_destroy(mgr: ?*zwlr_data_control_manager_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), ZWLR_DATA_CONTROL_MANAGER_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 1);
}

pub fn zwlr_data_control_device_v1_set_selection(device: ?*zwlr_data_control_device_v1, source: ?*zwlr_data_control_source_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(device)), ZWLR_DATA_CONTROL_DEVICE_V1_SET_SELECTION, null, c.wl_proxy_get_version(@ptrCast(@alignCast(device))), 0, source);
}

pub fn zwlr_data_control_device_v1_destroy(device: ?*zwlr_data_control_device_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(device)), ZWLR_DATA_CONTROL_DEVICE_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(device))), 1);
}

pub fn zwlr_data_control_source_v1_add_listener(source: ?*zwlr_data_control_source_v1, listener: [*c]const zwlr_data_control_source_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(source)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn zwlr_data_control_source_v1_offer(source: ?*zwlr_data_control_source_v1, mime_type: [*c]const u8) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(source)), ZWLR_DATA_CONTROL_SOURCE_V1_OFFER, null, c.wl_proxy_get_version(@ptrCast(@alignCast(source))), 0, mime_type);
}

pub fn zwlr_data_control_source_v1_destroy(source: ?*zwlr_data_control_source_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(source)), ZWLR_DATA_CONTROL_SOURCE_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(source))), 1);
}

pub fn ext_foreign_toplevel_list_v1_add_listener(list: ?*ext_foreign_toplevel_list_v1, listener: [*c]const ext_foreign_toplevel_list_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(list)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn ext_foreign_toplevel_list_v1_destroy(list: ?*ext_foreign_toplevel_list_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(list)), EXT_FOREIGN_TOPLEVEL_LIST_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(list))), 1);
}

pub fn ext_foreign_toplevel_handle_v1_add_listener(handle: ?*ext_foreign_toplevel_handle_v1, listener: [*c]const ext_foreign_toplevel_handle_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(handle)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn ext_foreign_toplevel_handle_v1_destroy(handle: ?*ext_foreign_toplevel_handle_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(handle)), EXT_FOREIGN_TOPLEVEL_HANDLE_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(handle))), 1);
}

pub fn ext_image_capture_source_v1_destroy(source: ?*ext_image_capture_source_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(source)), EXT_IMAGE_CAPTURE_SOURCE_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(source))), 1);
}

pub fn ext_foreign_toplevel_image_capture_source_manager_v1_create_source(mgr: ?*ext_foreign_toplevel_image_capture_source_manager_v1, handle: ?*ext_foreign_toplevel_handle_v1) callconv(.c) ?*ext_image_capture_source_v1 {
    const source = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), EXT_FOREIGN_TOPLEVEL_IMAGE_CAPTURE_SOURCE_MANAGER_V1_CREATE_SOURCE, &ext_image_capture_source_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 0, @as(?*anyopaque, null), handle);
    return @ptrCast(@alignCast(source));
}

pub fn ext_foreign_toplevel_image_capture_source_manager_v1_destroy(mgr: ?*ext_foreign_toplevel_image_capture_source_manager_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), EXT_FOREIGN_TOPLEVEL_IMAGE_CAPTURE_SOURCE_MANAGER_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 1);
}

pub fn ext_image_copy_capture_manager_v1_create_session(mgr: ?*ext_image_copy_capture_manager_v1, source: ?*ext_image_capture_source_v1, options: u32) callconv(.c) ?*ext_image_copy_capture_session_v1 {
    const session = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_CREATE_SESSION, &ext_image_copy_capture_session_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 0, @as(?*anyopaque, null), source, options);
    return @ptrCast(@alignCast(session));
}

pub fn ext_image_copy_capture_manager_v1_destroy(mgr: ?*ext_image_copy_capture_manager_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(mgr)), EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(mgr))), 1);
}

pub fn ext_image_copy_capture_session_v1_add_listener(session: ?*ext_image_copy_capture_session_v1, listener: [*c]const ext_image_copy_capture_session_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(session)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn ext_image_copy_capture_session_v1_create_frame(session: ?*ext_image_copy_capture_session_v1) callconv(.c) ?*ext_image_copy_capture_frame_v1 {
    const frame = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(session)), EXT_IMAGE_COPY_CAPTURE_SESSION_V1_CREATE_FRAME, &ext_image_copy_capture_frame_v1_interface, c.wl_proxy_get_version(@ptrCast(@alignCast(session))), 0, @as(?*anyopaque, null));
    return @ptrCast(@alignCast(frame));
}

pub fn ext_image_copy_capture_session_v1_destroy(session: ?*ext_image_copy_capture_session_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(session)), EXT_IMAGE_COPY_CAPTURE_SESSION_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(session))), 1);
}

pub fn ext_image_copy_capture_frame_v1_add_listener(frame: ?*ext_image_copy_capture_frame_v1, listener: [*c]const ext_image_copy_capture_frame_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(frame)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn ext_image_copy_capture_frame_v1_destroy(frame: ?*ext_image_copy_capture_frame_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(frame)), EXT_IMAGE_COPY_CAPTURE_FRAME_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(frame))), 1);
}

pub fn ext_image_copy_capture_frame_v1_attach_buffer(frame: ?*ext_image_copy_capture_frame_v1, buffer: ?*c.struct_wl_buffer) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(frame)), EXT_IMAGE_COPY_CAPTURE_FRAME_V1_ATTACH_BUFFER, null, c.wl_proxy_get_version(@ptrCast(@alignCast(frame))), 0, buffer);
}

pub fn ext_image_copy_capture_frame_v1_damage_buffer(frame: ?*ext_image_copy_capture_frame_v1, x: i32, y: i32, width: i32, height: i32) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(frame)), EXT_IMAGE_COPY_CAPTURE_FRAME_V1_DAMAGE_BUFFER, null, c.wl_proxy_get_version(@ptrCast(@alignCast(frame))), 0, x, y, width, height);
}

pub fn ext_image_copy_capture_frame_v1_capture(frame: ?*ext_image_copy_capture_frame_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(frame)), EXT_IMAGE_COPY_CAPTURE_FRAME_V1_CAPTURE, null, c.wl_proxy_get_version(@ptrCast(@alignCast(frame))), 0);
}

pub fn dotfiles_overview_v1_add_listener(overview: ?*dotfiles_overview_v1, listener: [*c]const dotfiles_overview_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(overview)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn dotfiles_overview_v1_destroy(overview: ?*dotfiles_overview_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(overview)), DOTFILES_OVERVIEW_V1_DESTROY, null, c.wl_proxy_get_version(@ptrCast(@alignCast(overview))), 1);
}

pub fn dotfiles_overview_v1_refresh(overview: ?*dotfiles_overview_v1) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(overview)), DOTFILES_OVERVIEW_V1_REFRESH, null, c.wl_proxy_get_version(@ptrCast(@alignCast(overview))), 0);
}

pub fn dotfiles_overview_v1_activate(overview: ?*dotfiles_overview_v1, identifier: [*c]const u8) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(overview)), DOTFILES_OVERVIEW_V1_ACTIVATE, null, c.wl_proxy_get_version(@ptrCast(@alignCast(overview))), 0, identifier);
}

pub fn dotfiles_overview_v1_close(overview: ?*dotfiles_overview_v1, identifier: [*c]const u8) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(overview)), DOTFILES_OVERVIEW_V1_CLOSE, null, c.wl_proxy_get_version(@ptrCast(@alignCast(overview))), 0, identifier);
}

pub fn dotfiles_overview_v1_switch_workspace(overview: ?*dotfiles_overview_v1, index: u32) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(overview)), DOTFILES_OVERVIEW_V1_SWITCH_WORKSPACE, null, c.wl_proxy_get_version(@ptrCast(@alignCast(overview))), 0, index);
}

pub fn dotfiles_overview_v1_move(overview: ?*dotfiles_overview_v1, identifier: [*c]const u8, index: u32) callconv(.c) void {
    _ = c.wl_proxy_marshal_flags(@ptrCast(@alignCast(overview)), DOTFILES_OVERVIEW_V1_MOVE, null, c.wl_proxy_get_version(@ptrCast(@alignCast(overview))), 0, identifier, index);
}

pub extern const ext_session_lock_manager_v1_interface: Interface;

pub extern const ext_session_lock_v1_interface: Interface;

pub extern const ext_session_lock_surface_v1_interface: Interface;

pub extern const ext_idle_notifier_v1_interface: Interface;

pub extern const ext_idle_notification_v1_interface: Interface;

pub extern const zwlr_output_manager_v1_interface: Interface;

pub extern const zwlr_output_head_v1_interface: Interface;

pub extern const zwlr_output_mode_v1_interface: Interface;

pub extern const zwlr_output_configuration_v1_interface: Interface;

pub extern const zwlr_output_configuration_head_v1_interface: Interface;

pub extern const xdg_wm_base_interface: Interface;

pub extern const xdg_positioner_interface: Interface;

pub extern const xdg_surface_interface: Interface;

pub extern const xdg_toplevel_interface: Interface;

pub extern const xdg_popup_interface: Interface;

pub extern const zwlr_layer_shell_v1_interface: Interface;

pub extern const zwlr_layer_surface_v1_interface: Interface;

pub extern const zxdg_output_manager_v1_interface: Interface;

pub extern const zxdg_output_v1_interface: Interface;

pub extern const zxdg_importer_v2_interface: Interface;

pub extern const zxdg_imported_v2_interface: Interface;
