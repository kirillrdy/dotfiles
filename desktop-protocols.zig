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
pub const ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT = @as(c_int, 1);

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
    overview: ?*const fn (data: ?*anyopaque, dotfiles_overview_v1: ?*dotfiles_overview_v1, active: u32) callconv(.c) void = null,
};

fn listen(proxy: anytype, listener: anytype, data: ?*anyopaque) c_int {
    return c.wl_proxy_add_listener(@ptrCast(@alignCast(proxy)), @ptrCast(@alignCast(@constCast(listener))), data);
}
fn send(proxy: anytype, opcode: u32, flags: u32, args: anytype) void {
    const p: ?*c.struct_wl_proxy = @ptrCast(@alignCast(proxy));
    _ = @call(.auto, c.wl_proxy_marshal_flags, .{ p, opcode, @as([*c]const Interface, null), c.wl_proxy_get_version(p), flags } ++ args);
}
fn create(comptime T: type, proxy: anytype, opcode: u32, iface: *const Interface, args: anytype) T {
    const p: ?*c.struct_wl_proxy = @ptrCast(@alignCast(proxy));
    return @ptrCast(@alignCast(@call(.auto, c.wl_proxy_marshal_flags, .{ p, opcode, @as([*c]const Interface, iface), c.wl_proxy_get_version(p), @as(u32, 0), @as(?*anyopaque, null) } ++ args)));
}
pub fn zwlr_screencopy_manager_v1_capture_output(mgr: ?*zwlr_screencopy_manager_v1, overlay_cursor: i32, output: ?*c.struct_wl_output) callconv(.c) ?*zwlr_screencopy_frame_v1 {
    return create(?*zwlr_screencopy_frame_v1, mgr, 0, &zwlr_screencopy_frame_v1_interface, .{ overlay_cursor, output });
}
pub fn zwlr_screencopy_manager_v1_capture_output_region(mgr: ?*zwlr_screencopy_manager_v1, overlay_cursor: i32, output: ?*c.struct_wl_output, x: i32, y: i32, width: i32, height: i32) callconv(.c) ?*zwlr_screencopy_frame_v1 {
    return create(?*zwlr_screencopy_frame_v1, mgr, 1, &zwlr_screencopy_frame_v1_interface, .{ overlay_cursor, output, x, y, width, height });
}
pub fn zwlr_screencopy_manager_v1_destroy(mgr: ?*zwlr_screencopy_manager_v1) callconv(.c) void {
    send(mgr, 2, 1, .{});
}
pub fn zwlr_screencopy_frame_v1_add_listener(frame: ?*zwlr_screencopy_frame_v1, listener: [*c]const zwlr_screencopy_frame_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return listen(frame, listener, data);
}
pub fn zwlr_screencopy_frame_v1_get_version(frame: ?*zwlr_screencopy_frame_v1) callconv(.c) u32 {
    return c.wl_proxy_get_version(@ptrCast(@alignCast(frame)));
}
pub fn zwlr_screencopy_frame_v1_copy(frame: ?*zwlr_screencopy_frame_v1, buffer: ?*c.struct_wl_buffer) callconv(.c) void {
    send(frame, 0, 0, .{buffer});
}
pub fn zwlr_screencopy_frame_v1_destroy(frame: ?*zwlr_screencopy_frame_v1) callconv(.c) void {
    send(frame, 1, 1, .{});
}
pub fn zwlr_data_control_manager_v1_create_data_source(mgr: ?*zwlr_data_control_manager_v1) callconv(.c) ?*zwlr_data_control_source_v1 {
    return create(?*zwlr_data_control_source_v1, mgr, 0, &zwlr_data_control_source_v1_interface, .{});
}
pub fn zwlr_data_control_manager_v1_get_data_device(mgr: ?*zwlr_data_control_manager_v1, seat: ?*c.struct_wl_seat) callconv(.c) ?*zwlr_data_control_device_v1 {
    return create(?*zwlr_data_control_device_v1, mgr, 1, &zwlr_data_control_device_v1_interface, .{seat});
}
pub fn zwlr_data_control_manager_v1_destroy(mgr: ?*zwlr_data_control_manager_v1) callconv(.c) void {
    send(mgr, 2, 1, .{});
}
pub fn zwlr_data_control_device_v1_set_selection(device: ?*zwlr_data_control_device_v1, source: ?*zwlr_data_control_source_v1) callconv(.c) void {
    send(device, 0, 0, .{source});
}
pub fn zwlr_data_control_device_v1_destroy(device: ?*zwlr_data_control_device_v1) callconv(.c) void {
    send(device, 1, 1, .{});
}
pub fn zwlr_data_control_source_v1_add_listener(source: ?*zwlr_data_control_source_v1, listener: [*c]const zwlr_data_control_source_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return listen(source, listener, data);
}
pub fn zwlr_data_control_source_v1_offer(source: ?*zwlr_data_control_source_v1, mime_type: [*c]const u8) callconv(.c) void {
    send(source, 0, 0, .{mime_type});
}
pub fn zwlr_data_control_source_v1_destroy(source: ?*zwlr_data_control_source_v1) callconv(.c) void {
    send(source, 1, 1, .{});
}
pub fn ext_foreign_toplevel_list_v1_add_listener(list: ?*ext_foreign_toplevel_list_v1, listener: [*c]const ext_foreign_toplevel_list_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return listen(list, listener, data);
}
pub fn ext_foreign_toplevel_list_v1_destroy(list: ?*ext_foreign_toplevel_list_v1) callconv(.c) void {
    send(list, 1, 1, .{});
}
pub fn ext_foreign_toplevel_handle_v1_add_listener(handle: ?*ext_foreign_toplevel_handle_v1, listener: [*c]const ext_foreign_toplevel_handle_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return listen(handle, listener, data);
}
pub fn ext_foreign_toplevel_handle_v1_destroy(handle: ?*ext_foreign_toplevel_handle_v1) callconv(.c) void {
    send(handle, 0, 1, .{});
}
pub fn ext_image_capture_source_v1_destroy(source: ?*ext_image_capture_source_v1) callconv(.c) void {
    send(source, 0, 1, .{});
}
pub fn ext_foreign_toplevel_image_capture_source_manager_v1_create_source(mgr: ?*ext_foreign_toplevel_image_capture_source_manager_v1, handle: ?*ext_foreign_toplevel_handle_v1) callconv(.c) ?*ext_image_capture_source_v1 {
    return create(?*ext_image_capture_source_v1, mgr, 0, &ext_image_capture_source_v1_interface, .{handle});
}
pub fn ext_foreign_toplevel_image_capture_source_manager_v1_destroy(mgr: ?*ext_foreign_toplevel_image_capture_source_manager_v1) callconv(.c) void {
    send(mgr, 1, 1, .{});
}
pub fn ext_image_copy_capture_manager_v1_create_session(mgr: ?*ext_image_copy_capture_manager_v1, source: ?*ext_image_capture_source_v1, options: u32) callconv(.c) ?*ext_image_copy_capture_session_v1 {
    return create(?*ext_image_copy_capture_session_v1, mgr, 0, &ext_image_copy_capture_session_v1_interface, .{ source, options });
}
pub fn ext_image_copy_capture_manager_v1_destroy(mgr: ?*ext_image_copy_capture_manager_v1) callconv(.c) void {
    send(mgr, 2, 1, .{});
}
pub fn ext_image_copy_capture_session_v1_add_listener(session: ?*ext_image_copy_capture_session_v1, listener: [*c]const ext_image_copy_capture_session_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return listen(session, listener, data);
}
pub fn ext_image_copy_capture_session_v1_create_frame(session: ?*ext_image_copy_capture_session_v1) callconv(.c) ?*ext_image_copy_capture_frame_v1 {
    return create(?*ext_image_copy_capture_frame_v1, session, 0, &ext_image_copy_capture_frame_v1_interface, .{});
}
pub fn ext_image_copy_capture_session_v1_destroy(session: ?*ext_image_copy_capture_session_v1) callconv(.c) void {
    send(session, 1, 1, .{});
}
pub fn ext_image_copy_capture_frame_v1_add_listener(frame: ?*ext_image_copy_capture_frame_v1, listener: [*c]const ext_image_copy_capture_frame_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return listen(frame, listener, data);
}
pub fn ext_image_copy_capture_frame_v1_destroy(frame: ?*ext_image_copy_capture_frame_v1) callconv(.c) void {
    send(frame, 0, 1, .{});
}
pub fn ext_image_copy_capture_frame_v1_attach_buffer(frame: ?*ext_image_copy_capture_frame_v1, buffer: ?*c.struct_wl_buffer) callconv(.c) void {
    send(frame, 1, 0, .{buffer});
}
pub fn ext_image_copy_capture_frame_v1_damage_buffer(frame: ?*ext_image_copy_capture_frame_v1, x: i32, y: i32, width: i32, height: i32) callconv(.c) void {
    send(frame, 2, 0, .{ x, y, width, height });
}
pub fn ext_image_copy_capture_frame_v1_capture(frame: ?*ext_image_copy_capture_frame_v1) callconv(.c) void {
    send(frame, 3, 0, .{});
}
pub fn dotfiles_overview_v1_add_listener(overview: ?*dotfiles_overview_v1, listener: [*c]const dotfiles_overview_v1_listener, data: ?*anyopaque) callconv(.c) c_int {
    return listen(overview, listener, data);
}
pub fn dotfiles_overview_v1_destroy(overview: ?*dotfiles_overview_v1) callconv(.c) void {
    send(overview, 0, 1, .{});
}
pub fn dotfiles_overview_v1_refresh(overview: ?*dotfiles_overview_v1) callconv(.c) void {
    send(overview, 1, 0, .{});
}
pub fn dotfiles_overview_v1_activate(overview: ?*dotfiles_overview_v1, identifier: [*c]const u8) callconv(.c) void {
    send(overview, 2, 0, .{identifier});
}
pub fn dotfiles_overview_v1_close(overview: ?*dotfiles_overview_v1, identifier: [*c]const u8) callconv(.c) void {
    send(overview, 3, 0, .{identifier});
}
pub fn dotfiles_overview_v1_switch_workspace(overview: ?*dotfiles_overview_v1, index: u32) callconv(.c) void {
    send(overview, 4, 0, .{index});
}
pub fn dotfiles_overview_v1_move(overview: ?*dotfiles_overview_v1, identifier: [*c]const u8, index: u32) callconv(.c) void {
    send(overview, 5, 0, .{ identifier, index });
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
