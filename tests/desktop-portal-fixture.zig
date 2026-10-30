const std = @import("std");
const c = @import("gtk");
fn cast(comptime T: type, value: anytype) *T {
    return @ptrCast(@alignCast(value));
}
var background: ?*c.GtkWidget = null;
var color = [3]f64{ 1, 0, 0 };
fn draw(_: *c.GtkWidget, cr: *c.cairo_t, _: ?*anyopaque) callconv(.c) c.gboolean {
    c.cairo_set_source_rgb(cr, color[0], color[1], color[2]);
    c.cairo_paint(cr);
    return 1;
}
fn toggleArea(widget: *c.GtkWidget) void {
    if (c.g_type_check_instance_is_a(cast(c.GTypeInstance, widget), c.gtk_toggle_button_get_type()) != 0) {
        c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, widget), 1);
    } else if (c.g_type_check_instance_is_a(cast(c.GTypeInstance, widget), c.gtk_container_get_type()) != 0) {
        const children = c.gtk_container_get_children(cast(c.GtkContainer, widget));
        defer c.g_list_free(children);
        var item = children;
        while (item != null) : (item = item.*.next) toggleArea(cast(c.GtkWidget, item.*.data));
    }
}
fn method(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, name: [*c]const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, _: ?*anyopaque) callconv(.c) void {
    if (std.mem.eql(u8, std.mem.span(name), "Color")) {
        for (0..3) |i| {
            const value = c.g_variant_get_child_value(params, i);
            color[i] = c.g_variant_get_double(value);
            c.g_variant_unref(value);
        }
        if (background == null) {
            _ = c.gtk_init_check(null, null);
            const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
            background = window;
            c.gtk_widget_set_app_paintable(window, 1);
            c.gtk_layer_init_for_window(cast(c.GtkWindow, window));
            c.gtk_layer_set_layer(cast(c.GtkWindow, window), c.GTK_LAYER_SHELL_LAYER_BACKGROUND);
            for ([_]c_uint{ c.GTK_LAYER_SHELL_EDGE_TOP, c.GTK_LAYER_SHELL_EDGE_BOTTOM, c.GTK_LAYER_SHELL_EDGE_LEFT, c.GTK_LAYER_SHELL_EDGE_RIGHT }) |edge| c.gtk_layer_set_anchor(cast(c.GtkWindow, window), edge, 1);
            _ = c.g_signal_connect_data(window, "draw", @ptrCast(&draw), null, null, 0);
            c.gtk_widget_show_all(window);
        }
        c.gtk_widget_queue_draw(background.?);
        c.g_dbus_method_invocation_return_value(invocation, null);
        return;
    }
    const title_value = c.g_variant_get_child_value(params, 0);
    defer c.g_variant_unref(title_value);
    const accepted = c.g_variant_get_child_value(params, 1);
    defer c.g_variant_unref(accepted);
    const area = c.g_variant_get_child_value(params, 2);
    defer c.g_variant_unref(area);
    var found: c_int = 0;
    const windows = c.gtk_window_list_toplevels();
    defer c.g_list_free(windows);
    var item = windows;
    while (item != null) : (item = item.*.next) {
        const window = cast(c.GtkWidget, item.*.data);
        const title = c.gtk_window_get_title(cast(c.GtkWindow, window));
        if (title != null and c.gtk_widget_get_visible(window) != 0 and std.mem.eql(u8, std.mem.span(title), std.mem.span(c.g_variant_get_string(title_value, null)))) {
            if (c.g_variant_get_boolean(area) != 0) toggleArea(window);
            c.gtk_dialog_response(cast(c.GtkDialog, window), if (c.g_variant_get_boolean(accepted) != 0) c.GTK_RESPONSE_OK else c.GTK_RESPONSE_CANCEL);
            found = 1;
            break;
        }
    }
    c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(b)", found));
}
const vtable = c.GDBusInterfaceVTable{ .method_call = &method };
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (allocator.deinit() == .leak) @panic("portal allocation leak");
    const connection = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return error.NoBus;
    defer c.g_object_unref(connection);
    const node = c.g_dbus_node_info_new_for_xml("<node><interface name='org.dotfiles.CaptureFixture'><method name='Reply'><arg type='s' direction='in'/><arg type='b' direction='in'/><arg type='b' direction='in'/><arg type='b' direction='out'/></method><method name='Color'><arg type='d' direction='in'/><arg type='d' direction='in'/><arg type='d' direction='in'/></method></interface></node>", null) orelse return error.InvalidXml;
    defer c.g_dbus_node_info_unref(node);
    const registration = if (c.g_getenv("DESKTOP_PORTAL_FIXTURE_CAPTURE") != null) c.g_dbus_connection_register_object(connection, "/org/dotfiles/CaptureFixture", node.*.interfaces[0], &vtable, null, null, null) else 0;
    defer {
        if (registration != 0) _ = c.g_dbus_connection_unregister_object(connection, registration);
    }
    defer if (background) |window| c.gtk_widget_destroy(window);
    try @import("portal").runWithAllocator(allocator.allocator());
}
