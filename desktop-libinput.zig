//! The part of libinput and libudev the compositor uses: device discovery on
//! a seat, keyboard keys, pointer motion, buttons and scrolling, and the
//! udev monitor that reports display hotplug.
const std = @import("std");

pub const Libinput = opaque {};
pub const Event = opaque {};
pub const Device = opaque {};
pub const KeyboardEvent = opaque {};
pub const PointerEvent = opaque {};
pub const Udev = opaque {};
pub const UdevMonitor = opaque {};
pub const UdevDevice = opaque {};

pub const Interface = extern struct {
    open_restricted: *const fn (path: [*:0]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int,
    close_restricted: *const fn (fd: c_int, user_data: ?*anyopaque) callconv(.c) void,
};

/// enum libinput_event_type
pub const EventType = struct {
    pub const device_added: c_int = 1;
    pub const device_removed: c_int = 2;
    pub const keyboard_key: c_int = 300;
    pub const pointer_motion: c_int = 400;
    pub const pointer_motion_absolute: c_int = 401;
    pub const pointer_button: c_int = 402;
    pub const pointer_scroll_wheel: c_int = 404;
    pub const pointer_scroll_finger: c_int = 405;
    pub const pointer_scroll_continuous: c_int = 406;
};

pub const axis_vertical: c_int = 0;
pub const axis_horizontal: c_int = 1;
pub const capability_keyboard: c_int = 0;
pub const capability_pointer: c_int = 1;
pub const tap_disabled: c_int = 0;

pub extern fn udev_new() ?*Udev;
pub extern fn udev_unref(*Udev) ?*Udev;
pub extern fn udev_monitor_new_from_netlink(*Udev, name: [*:0]const u8) ?*UdevMonitor;
pub extern fn udev_monitor_filter_add_match_subsystem_devtype(*UdevMonitor, subsystem: [*:0]const u8, devtype: ?[*:0]const u8) c_int;
pub extern fn udev_monitor_enable_receiving(*UdevMonitor) c_int;
pub extern fn udev_monitor_get_fd(*UdevMonitor) c_int;
pub extern fn udev_monitor_receive_device(*UdevMonitor) ?*UdevDevice;
pub extern fn udev_monitor_unref(*UdevMonitor) ?*UdevMonitor;
pub extern fn udev_device_unref(*UdevDevice) ?*UdevDevice;

pub extern fn libinput_udev_create_context(*const Interface, user_data: ?*anyopaque, *Udev) ?*Libinput;
pub extern fn libinput_udev_assign_seat(*Libinput, seat: [*:0]const u8) c_int;
pub extern fn libinput_unref(*Libinput) ?*Libinput;
pub extern fn libinput_get_fd(*Libinput) c_int;
pub extern fn libinput_dispatch(*Libinput) c_int;
pub extern fn libinput_get_event(*Libinput) ?*Event;
pub extern fn libinput_suspend(*Libinput) void;
pub extern fn libinput_resume(*Libinput) c_int;
pub extern fn libinput_event_destroy(*Event) void;
pub extern fn libinput_event_get_type(*Event) c_int;
pub extern fn libinput_event_get_device(*Event) *Device;
pub extern fn libinput_device_has_capability(*Device, capability: c_int) c_int;
pub extern fn libinput_device_config_tap_get_finger_count(*Device) c_int;
pub extern fn libinput_device_config_tap_set_enabled(*Device, enable: c_int) c_int;
pub extern fn libinput_device_config_scroll_set_natural_scroll_enabled(*Device, enable: c_int) c_int;
pub extern fn libinput_device_config_scroll_get_natural_scroll_enabled(*Device) c_int;
pub extern fn libinput_device_led_update(*Device, leds: c_int) void;
pub extern fn libinput_device_ref(*Device) *Device;
pub extern fn libinput_device_unref(*Device) ?*Device;
pub const led_num_lock: c_int = 1 << 0;
pub const led_caps_lock: c_int = 1 << 1;
pub const led_scroll_lock: c_int = 1 << 2;

pub extern fn libinput_event_get_keyboard_event(*Event) *KeyboardEvent;
pub extern fn libinput_event_keyboard_get_time(*KeyboardEvent) u32;
pub extern fn libinput_event_keyboard_get_key(*KeyboardEvent) u32;
pub extern fn libinput_event_keyboard_get_key_state(*KeyboardEvent) c_int;

pub extern fn libinput_event_get_pointer_event(*Event) *PointerEvent;
pub extern fn libinput_event_pointer_get_time(*PointerEvent) u32;
pub extern fn libinput_event_pointer_get_dx(*PointerEvent) f64;
pub extern fn libinput_event_pointer_get_dy(*PointerEvent) f64;
pub extern fn libinput_event_pointer_get_absolute_x_transformed(*PointerEvent, width: u32) f64;
pub extern fn libinput_event_pointer_get_absolute_y_transformed(*PointerEvent, height: u32) f64;
pub extern fn libinput_event_pointer_get_button(*PointerEvent) u32;
pub extern fn libinput_event_pointer_get_button_state(*PointerEvent) c_int;
pub extern fn libinput_event_pointer_has_axis(*PointerEvent, axis: c_int) c_int;
pub extern fn libinput_event_pointer_get_scroll_value(*PointerEvent, axis: c_int) f64;
pub extern fn libinput_event_pointer_get_scroll_value_v120(*PointerEvent, axis: c_int) f64;

test "libinput constants match its header" {
    const c = @import("libinput-reference");
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_EVENT_DEVICE_ADDED), EventType.device_added);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_EVENT_DEVICE_REMOVED), EventType.device_removed);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_EVENT_KEYBOARD_KEY), EventType.keyboard_key);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_EVENT_POINTER_MOTION), EventType.pointer_motion);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_EVENT_POINTER_MOTION_ABSOLUTE), EventType.pointer_motion_absolute);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_EVENT_POINTER_BUTTON), EventType.pointer_button);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_EVENT_POINTER_SCROLL_WHEEL), EventType.pointer_scroll_wheel);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_EVENT_POINTER_SCROLL_FINGER), EventType.pointer_scroll_finger);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_EVENT_POINTER_SCROLL_CONTINUOUS), EventType.pointer_scroll_continuous);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL), axis_vertical);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL), axis_horizontal);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_DEVICE_CAP_KEYBOARD), capability_keyboard);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_DEVICE_CAP_POINTER), capability_pointer);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_CONFIG_TAP_DISABLED), tap_disabled);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_LED_NUM_LOCK), led_num_lock);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_LED_CAPS_LOCK), led_caps_lock);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_LED_SCROLL_LOCK), led_scroll_lock);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_KEY_STATE_PRESSED), 1);
    try std.testing.expectEqual(@as(c_int, c.LIBINPUT_BUTTON_STATE_PRESSED), 1);
    // The interface is two function pointers in this order.
    try std.testing.expectEqual(@sizeOf(c.struct_libinput_interface), @sizeOf(Interface));
    try std.testing.expectEqual(@offsetOf(c.struct_libinput_interface, "close_restricted"), @offsetOf(Interface, "close_restricted"));
}
