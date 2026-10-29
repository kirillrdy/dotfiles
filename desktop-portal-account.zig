//! Account information is released only after explicit consent in a native dialog.
const std = @import("std");
const c = @import("gtk");
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
pub const Completion = *const fn (?*anyopaque, u32, ?*c.GVariant) void;
pub const Dialog = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    window: *c.GtkWidget,
    id: [:0]const u8,
    name: [:0]const u8,
    image: [:0]const u8,
    callback: Completion,
    data: ?*anyopaque,
    finished: bool = false,

    pub fn create(allocator: std.mem.Allocator, app: [:0]const u8, parent: [:0]const u8, options: *c.GVariant, callback: Completion, data: ?*anyopaque) !*Dialog {
        const reason = c.g_variant_lookup_value(options, "reason", null);
        defer if (reason != null) c.g_variant_unref(reason);
        if (reason != null and !std.mem.eql(u8, std.mem.span(c.g_variant_get_type_string(reason)), "s")) return error.InvalidAccountReason;
        if (c.gtk_init_check(null, null) == 0) return error.DisplayUnavailable;
        const self = try allocator.create(Dialog);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .window = c.gtk_dialog_new_with_buttons("Share account information", null, 0, @as([*:0]const u8, "_Cancel"), c.GTK_RESPONSE_CANCEL, @as([*:0]const u8, "_Share"), c.GTK_RESPONSE_OK, @as(?*anyopaque, null)),
            .id = undefined,
            .name = undefined,
            .image = "",
            .callback = callback,
            .data = data,
        };
        errdefer self.destroy();
        const a = self.arena.allocator();
        self.id = try a.dupeSentinel(u8, std.mem.span(c.g_get_user_name()), 0);
        const real = std.mem.span(c.g_get_real_name());
        self.name = try a.dupeSentinel(u8, if (std.mem.eql(u8, real, "Unknown") or real.len == 0) self.id else real, 0);
        const face = try std.fmt.allocPrintSentinel(a, "{s}/.face", .{c.g_get_home_dir()}, 0);
        const file = c.g_file_new_for_path(face);
        defer c.g_object_unref(file);
        if (c.g_file_query_file_type(file, 0, null) == 1) {
            const uri = c.g_file_get_uri(file);
            defer c.g_free(uri);
            self.image = try a.dupeSentinel(u8, std.mem.span(uri), 0);
        }
        c.gtk_window_set_modal(cast(c.GtkWindow, self.window), 1);
        c.gtk_window_set_default_size(cast(c.GtkWindow, self.window), 420, -1);
        c.gtk_dialog_set_default_response(cast(c.GtkDialog, self.window), c.GTK_RESPONSE_CANCEL);
        const content = c.gtk_dialog_get_content_area(cast(c.GtkDialog, self.window));
        c.gtk_container_set_border_width(cast(c.GtkContainer, content), 18);
        c.gtk_box_set_spacing(cast(c.GtkBox, content), 12);
        self.label(content, try std.fmt.allocPrintSentinel(a, "{s} wants to access your account information.", .{app}, 0));
        if (reason != null) self.label(content, c.g_variant_get_string(reason, null));
        self.label(content, try std.fmt.allocPrintSentinel(a, "Name: {s}\nUser name: {s}", .{ self.name, self.id }, 0));
        if (self.image.len > 0) self.label(content, "Your account picture will also be shared.");
        _ = c.g_signal_connect_data(self.window, "response", @ptrCast(&responded), self, null, 0);
        c.gtk_widget_show_all(self.window);
        c.gtk_window_present(cast(c.GtkWindow, self.window));
        @import("desktop-portal-window.zig").parentTo(self.window, allocator, parent);
        return self;
    }
    fn label(_: *Dialog, content: *c.GtkWidget, value: [*:0]const u8) void {
        const widget = c.gtk_label_new(value);
        c.gtk_label_set_line_wrap(cast(c.GtkLabel, widget), 1);
        c.gtk_label_set_xalign(cast(c.GtkLabel, widget), 0);
        c.gtk_box_pack_start(cast(c.GtkBox, content), widget, 0, 0, 0);
    }
    pub fn destroy(self: *Dialog) void {
        _ = c.g_signal_handlers_disconnect_matched(self.window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_widget_destroy(self.window);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    fn responded(_: *c.GtkDialog, response: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Dialog, data);
        if (self.finished) return;
        self.finished = true;
        c.gtk_widget_hide(self.window);
        const values = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
        defer c.g_variant_builder_unref(values);
        const accepted = response == c.GTK_RESPONSE_OK;
        if (accepted) {
            c.g_variant_builder_add(values, "{sv}", @as([*:0]const u8, "id"), c.g_variant_new("s", self.id.ptr));
            c.g_variant_builder_add(values, "{sv}", @as([*:0]const u8, "name"), c.g_variant_new("s", self.name.ptr));
            c.g_variant_builder_add(values, "{sv}", @as([*:0]const u8, "image"), c.g_variant_new("s", self.image.ptr));
        }
        self.callback(self.data, if (accepted) 0 else 1, c.g_variant_builder_end(values));
    }
};
