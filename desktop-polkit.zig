//! PolicyKit authentication agent with a native GNOME-style GTK dialog.
const std = @import("std");
pub const c = @import("desktop-gtk.zig");
const libc = @import("desktop-libc.zig");

const cast = c.__zig.cast;

pub const Dialog = struct {
    window: *c.GtkWidget,
    prompt: *c.GtkWidget,
    action_label: ?*c.GtkWidget,
    user_label: ?*c.GtkWidget,
    entry: *c.GtkWidget,
    error_label: *c.GtkWidget,
    auth_button: *c.GtkWidget,
    pub fn create(
        action_id: ?[:0]const u8,
        message: [:0]const u8,
        user: ?[:0]const u8,
        icon_name: ?[:0]const u8,
    ) Dialog {
        const window = c.gtk_dialog_new();
        c.gtk_window_set_title(cast(c.GtkWindow, window), "Authentication Required");
        c.gtk_window_set_role(cast(c.GtkWindow, window), "desktop-polkit");
        c.gtk_window_set_type_hint(cast(c.GtkWindow, window), c.GDK_WINDOW_TYPE_HINT_DIALOG);
        c.gtk_window_set_icon_name(cast(c.GtkWindow, window), if (icon_name) |name| name.ptr else "dialog-password");
        c.gtk_window_set_modal(cast(c.GtkWindow, window), 1);
        c.gtk_window_set_keep_above(cast(c.GtkWindow, window), 1);
        c.gtk_window_set_resizable(cast(c.GtkWindow, window), 0);
        c.gtk_window_set_position(cast(c.GtkWindow, window), c.GTK_WIN_POS_CENTER);
        c.gtk_window_set_default_size(cast(c.GtkWindow, window), 460, -1);

        const content = c.gtk_dialog_get_content_area(cast(c.GtkDialog, window));
        c.gtk_container_set_border_width(cast(c.GtkContainer, content), 18);
        c.gtk_box_set_spacing(cast(c.GtkBox, content), 14);

        const header_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12);
        const icon = c.gtk_image_new_from_icon_name(if (icon_name) |name| name.ptr else "dialog-password", c.GTK_ICON_SIZE_DIALOG);
        c.gtk_box_pack_start(cast(c.GtkBox, header_box), icon, 0, 0, 0);

        const header_vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
        const title_label = c.gtk_label_new(null);
        c.gtk_label_set_markup(cast(c.GtkLabel, title_label), "<span weight=\"bold\" size=\"larger\">Authentication Required</span>");
        c.gtk_label_set_xalign(cast(c.GtkLabel, title_label), 0);
        c.gtk_box_pack_start(cast(c.GtkBox, header_vbox), title_label, 0, 0, 0);

        const prompt = c.gtk_label_new(message.ptr);
        c.gtk_label_set_xalign(cast(c.GtkLabel, prompt), 0);
        c.gtk_label_set_line_wrap(cast(c.GtkLabel, prompt), 1);
        c.gtk_label_set_max_width_chars(cast(c.GtkLabel, prompt), 55);
        c.gtk_box_pack_start(cast(c.GtkBox, header_vbox), prompt, 0, 0, 0);
        c.gtk_box_pack_start(cast(c.GtkBox, header_box), header_vbox, 1, 1, 0);
        c.gtk_box_pack_start(cast(c.GtkBox, content), header_box, 0, 0, 0);

        var action_label: ?*c.GtkWidget = null;
        if (action_id) |action| {
            action_label = c.gtk_label_new(null);
            var buf: [256:0]u8 = undefined;
            const escaped = c.g_markup_escape_text(action.ptr, @intCast(action.len));
            defer c.g_free(escaped);
            const text = std.fmt.bufPrintSentinel(&buf, "<span size=\"smaller\" color=\"#949497\">Action: {s}</span>", .{std.mem.span(escaped)}, 0) catch "Action";
            c.gtk_label_set_markup(cast(c.GtkLabel, action_label.?), text.ptr);
            c.gtk_label_set_xalign(cast(c.GtkLabel, action_label.?), 0);
            c.gtk_box_pack_start(cast(c.GtkBox, content), action_label.?, 0, 0, 0);
        }

        var user_label: ?*c.GtkWidget = null;
        if (user) |username| {
            user_label = c.gtk_label_new(null);
            var buf: [256:0]u8 = undefined;
            const escaped = c.g_markup_escape_text(username.ptr, @intCast(username.len));
            defer c.g_free(escaped);
            const text = std.fmt.bufPrintSentinel(&buf, "Password for <b>{s}</b>:", .{std.mem.span(escaped)}, 0) catch "Password:";
            c.gtk_label_set_markup(cast(c.GtkLabel, user_label.?), text.ptr);
            c.gtk_label_set_xalign(cast(c.GtkLabel, user_label.?), 0);
            c.gtk_box_pack_start(cast(c.GtkBox, content), user_label.?, 0, 0, 0);
        }

        const entry = c.gtk_entry_new();
        c.gtk_entry_set_visibility(cast(c.GtkEntry, entry), 0);
        c.gtk_entry_set_input_purpose(cast(c.GtkEntry, entry), c.GTK_INPUT_PURPOSE_PASSWORD);
        c.gtk_entry_set_activates_default(cast(c.GtkEntry, entry), 1);
        c.gtk_box_pack_start(cast(c.GtkBox, content), entry, 0, 0, 0);

        const error_label = c.gtk_label_new(null);
        c.gtk_label_set_xalign(cast(c.GtkLabel, error_label), 0);
        c.gtk_label_set_line_wrap(cast(c.GtkLabel, error_label), 1);
        c.gtk_widget_set_no_show_all(error_label, 1);
        c.gtk_box_pack_start(cast(c.GtkBox, content), error_label, 0, 0, 0);

        _ = c.gtk_dialog_add_button(cast(c.GtkDialog, window), "Cancel", c.GTK_RESPONSE_CANCEL);
        const auth_button = c.gtk_dialog_add_button(cast(c.GtkDialog, window), "Authenticate", c.GTK_RESPONSE_OK);
        c.gtk_dialog_set_default_response(cast(c.GtkDialog, window), c.GTK_RESPONSE_OK);

        c.gtk_widget_show_all(window);
        c.gtk_widget_grab_focus(entry);

        return .{
            .window = window,
            .prompt = prompt,
            .action_label = action_label,
            .user_label = user_label,
            .entry = entry,
            .error_label = error_label,
            .auth_button = auth_button,
        };
    }

    pub fn setError(self: *Dialog, message: []const u8) void {
        var buf: [512:0]u8 = undefined;
        const escaped = c.g_markup_escape_text(message.ptr, @intCast(message.len));
        defer c.g_free(escaped);
        const text = std.fmt.bufPrintSentinel(&buf, "<span color=\"#ef4444\" weight=\"bold\">{s}</span>", .{std.mem.span(escaped)}, 0) catch return;
        c.gtk_label_set_markup(cast(c.GtkLabel, self.error_label), text.ptr);
        c.gtk_widget_show(self.error_label);
    }

    pub fn clear(self: *Dialog) void {
        c.gtk_entry_set_text(cast(c.GtkEntry, self.entry), "");
    }

    pub fn destroy(self: *Dialog) void {
        self.clear();
        c.gtk_widget_destroy(self.window);
    }
};

pub const Service = @import("desktop-polkit-agent.zig").Service;
