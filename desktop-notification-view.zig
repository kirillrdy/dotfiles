//! GNOME Shell 50 notification cards, shared by banners and the date menu.
const std = @import("std");
pub const c = @import("gtk");
const allocator = std.heap.page_allocator;
const cast = c.__zig.cast;
pub fn css(widget: [*c]c.GtkWidget, name: [*:0]const u8) void {
    c.gtk_style_context_add_class(c.gtk_widget_get_style_context(widget), name);
}
pub const Action = struct { key: [:0]const u8, label: [:0]const u8 };
pub const Data = struct {
    id: u32,
    app: [:0]const u8,
    title: [:0]const u8,
    body: [:0]const u8,
    icon: [:0]const u8 = "application-x-executable-symbolic",
    image: ?*c.GdkPixbuf = null,
    actions: []const Action = &.{},
    created: i64,
};
pub const Callbacks = struct {
    context: ?*anyopaque,
    close: *const fn (?*anyopaque, u32) void,
    activate: *const fn (?*anyopaque, u32, [:0]const u8) void,
    resized: ?*const fn (?*anyopaque) void = null,
};
pub const View = struct {
    root: *c.GtkWidget,
    body: *c.GtkWidget,
    expand: *c.GtkWidget,
    action_box: *c.GtkWidget,
    time: *c.GtkWidget,
    id: u32,
    created: i64,
    expanded: bool = false,
    actions: bool,
    callbacks: Callbacks,

    pub fn create(data: Data, callbacks: Callbacks) *View {
        const self = allocator.create(View) catch @panic("out of memory");
        const root = c.gtk_event_box_new();
        c.gtk_event_box_set_visible_window(cast(c.GtkEventBox, root), 0);
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        css(box, "desktop-notification");
        c.gtk_container_add(cast(c.GtkContainer, root), box);
        const header = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        css(header, "notification-header");
        c.gtk_widget_set_size_request(header, -1, 34);
        c.gtk_box_pack_start(cast(c.GtkBox, box), header, 0, 0, 0);
        const icon = c.gtk_image_new();
        if (c.g_path_is_absolute(data.icon) != 0) c.gtk_image_set_from_file(cast(c.GtkImage, icon), data.icon) else c.gtk_image_set_from_icon_name(cast(c.GtkImage, icon), data.icon, c.GTK_ICON_SIZE_MENU);
        c.gtk_image_set_pixel_size(cast(c.GtkImage, icon), 16);
        c.gtk_widget_set_size_request(icon, 16, 16);
        c.gtk_widget_set_margin_start(icon, 6);
        c.gtk_widget_set_valign(icon, c.GTK_ALIGN_CENTER);
        css(icon, "notification-source-icon");
        c.gtk_box_pack_start(cast(c.GtkBox, header), icon, 0, 0, 0);
        const source = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        css(source, "notification-source");
        c.gtk_widget_set_valign(source, c.GTK_ALIGN_CENTER);
        const app = c.gtk_label_new(if (data.app.len == 0) "Unknown App" else data.app);
        css(app, "notification-app");
        c.gtk_label_set_ellipsize(cast(c.GtkLabel, app), c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_set_valign(app, c.GTK_ALIGN_END);
        c.gtk_box_pack_start(cast(c.GtkBox, source), app, 0, 0, 0);
        const time = c.gtk_label_new("Just now");
        css(time, "notification-time");
        c.gtk_widget_set_valign(time, c.GTK_ALIGN_END);
        c.gtk_box_pack_start(cast(c.GtkBox, source), time, 0, 0, 0);
        c.gtk_box_pack_start(cast(c.GtkBox, header), source, 1, 1, 0);
        const expand = iconButton("notification-expand-symbolic");
        css(expand, "notification-expand");
        c.gtk_widget_show_all(expand);
        c.gtk_widget_hide(expand);
        c.gtk_widget_set_no_show_all(expand, 1);
        c.gtk_widget_set_tooltip_text(expand, "Expand notification");
        c.gtk_box_pack_start(cast(c.GtkBox, header), expand, 0, 0, 0);
        const close = iconButton("window-close-symbolic");
        css(close, "notification-close");
        c.gtk_widget_set_tooltip_text(close, "Close notification");
        c.gtk_box_pack_start(cast(c.GtkBox, header), close, 0, 0, 0);
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12);
        css(row, "notification-content-row");
        c.gtk_box_pack_start(cast(c.GtkBox, box), row, 0, 0, 0);
        if (data.image) |pixbuf| {
            const scaled = c.gdk_pixbuf_scale_simple(pixbuf, 48, 48, c.GDK_INTERP_BILINEAR);
            const image = c.gtk_image_new_from_pixbuf(scaled);
            c.g_object_unref(scaled);
            c.gtk_widget_set_valign(image, c.GTK_ALIGN_START);
            c.gtk_box_pack_start(cast(c.GtkBox, row), image, 0, 0, 0);
        }
        const content = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
        c.gtk_widget_set_margin_end(content, 6);
        c.gtk_box_pack_start(cast(c.GtkBox, row), content, 1, 1, 0);
        const title = c.gtk_label_new(data.title);
        c.gtk_label_set_xalign(cast(c.GtkLabel, title), 0);
        c.gtk_label_set_ellipsize(cast(c.GtkLabel, title), c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_set_size_request(title, -1, 19);
        css(title, "notification-title");
        c.gtk_box_pack_start(cast(c.GtkBox, content), title, 0, 0, 0);
        const body = c.gtk_label_new(null);
        setMarkup(body, data.body);
        c.gtk_label_set_xalign(cast(c.GtkLabel, body), 0);
        c.gtk_label_set_yalign(cast(c.GtkLabel, body), 0);
        c.gtk_label_set_line_wrap(cast(c.GtkLabel, body), 1);
        c.gtk_label_set_line_wrap_mode(cast(c.GtkLabel, body), c.PANGO_WRAP_WORD_CHAR);
        c.gtk_label_set_lines(cast(c.GtkLabel, body), 1);
        c.gtk_label_set_ellipsize(cast(c.GtkLabel, body), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_max_width_chars(cast(c.GtkLabel, body), 1);
        c.gtk_widget_set_size_request(body, -1, 19);
        css(body, "notification-body");
        c.gtk_box_pack_start(cast(c.GtkBox, content), body, 0, 0, 0);
        const action_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        css(action_box, "notification-actions");
        c.gtk_widget_set_no_show_all(action_box, 1);
        c.gtk_box_set_homogeneous(cast(c.GtkBox, action_box), 1);
        c.gtk_box_pack_start(cast(c.GtkBox, box), action_box, 0, 0, 0);
        var count: usize = 0;
        for (data.actions) |action| {
            if (std.mem.eql(u8, action.key, "default") or count == 3) continue;
            const button = c.gtk_button_new_with_label(action.label);
            css(button, "notification-action");
            c.g_object_set_data_full(cast(c.GObject, button), "action", c.g_strdup(action.key), &c.g_free);
            _ = c.g_signal_connect_data(button, "clicked", @ptrCast(&actionClicked), self, null, 0);
            c.gtk_box_pack_start(cast(c.GtkBox, action_box), button, 1, 1, 0);
            count += 1;
        }
        c.gtk_widget_set_no_show_all(action_box, 0);
        c.gtk_widget_show_all(action_box);
        c.gtk_widget_hide(action_box);
        c.gtk_widget_set_no_show_all(action_box, 1);
        self.* = .{ .root = root, .body = body, .expand = expand, .action_box = action_box, .time = time, .id = data.id, .created = data.created, .actions = count > 0, .callbacks = callbacks };
        c.gtk_widget_set_visible(expand, @intFromBool(count > 0));
        _ = c.g_signal_connect_data(root, "destroy", @ptrCast(&destroyed), self, null, 0);
        _ = c.g_signal_connect_data(root, "button-press-event", @ptrCast(&activated), self, null, 0);
        _ = c.g_signal_connect_data(close, "clicked", @ptrCast(&closed), self, null, 0);
        _ = c.g_signal_connect_data(expand, "clicked", @ptrCast(&expandClicked), self, null, 0);
        _ = c.g_signal_connect_data(body, "size-allocate", @ptrCast(&allocated), self, null, 0);
        c.gtk_widget_show_all(root);
        self.updateTime();
        return self;
    }

    pub fn updateTime(self: *View) void {
        const age = @max(0, @divTrunc(c.g_get_real_time(), 1000000) - self.created);
        var buffer: [64]u8 = undefined;
        const text: [:0]const u8 = if (age < 60) "Just now" else if (age < 3600) std.fmt.bufPrintSentinel(&buffer, "{d}m ago", .{@divTrunc(age, 60)}, 0) catch unreachable else std.fmt.bufPrintSentinel(&buffer, "{d}h ago", .{@divTrunc(age, 3600)}, 0) catch unreachable;
        c.gtk_label_set_text(cast(c.GtkLabel, self.time), text);
    }
    fn allocated(_: *c.GtkWidget, _: *c.GtkAllocation, data: c.gpointer) callconv(.c) void {
        const self = cast(View, data);
        const ellipsized = c.pango_layout_is_ellipsized(c.gtk_label_get_layout(cast(c.GtkLabel, self.body))) != 0;
        c.gtk_widget_set_visible(self.expand, @intFromBool(self.expanded or self.actions or ellipsized));
    }
    fn expandClicked(button: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self = cast(View, data);
        self.expanded = !self.expanded;
        c.gtk_label_set_lines(cast(c.GtkLabel, self.body), if (self.expanded) 6 else 1);
        c.gtk_widget_set_visible(self.action_box, @intFromBool(self.expanded and self.actions));
        if (self.expanded and self.actions) c.gtk_widget_show_all(self.action_box);
        const image_style = c.gtk_widget_get_style_context(c.gtk_button_get_image(button));
        if (self.expanded) c.gtk_style_context_add_class(image_style, "expanded") else c.gtk_style_context_remove_class(image_style, "expanded");
        if (self.callbacks.resized) |resized| resized(self.callbacks.context);
    }
    fn activated(_: *c.GtkWidget, event: *c.GdkEventButton, data: c.gpointer) callconv(.c) c.gboolean {
        if (event.button != 1) return 0;
        const self = cast(View, data);
        var widget = c.gtk_get_event_widget(@ptrCast(event));
        while (widget != null and widget != self.root) : (widget = c.gtk_widget_get_parent(widget)) {
            if (c.g_type_check_instance_is_a(cast(c.GTypeInstance, widget), c.gtk_button_get_type()) != 0) return 0;
        }
        self.callbacks.activate(self.callbacks.context, self.id, "default");
        return 1;
    }
    fn actionClicked(button: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self = cast(View, data);
        const key: [*:0]const u8 = @ptrCast(c.g_object_get_data(cast(c.GObject, button), "action"));
        self.callbacks.activate(self.callbacks.context, self.id, std.mem.span(key));
    }
    fn closed(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self = cast(View, data);
        self.callbacks.close(self.callbacks.context, self.id);
    }
    fn destroyed(_: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
        allocator.destroy(cast(View, data));
    }
};
fn iconButton(icon: [*:0]const u8) *c.GtkWidget {
    const button = c.gtk_button_new_from_icon_name(icon, c.GTK_ICON_SIZE_MENU);
    c.gtk_widget_set_valign(button, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_can_focus(button, 1);
    return button;
}
pub fn setMarkup(widget: *c.GtkWidget, text: [:0]const u8) void {
    var err: [*c]c.GError = null;
    if (c.pango_parse_markup(text, -1, 0, null, null, null, &err) != 0) c.gtk_label_set_markup(cast(c.GtkLabel, widget), text) else {
        c.g_clear_error(&err);
        c.gtk_label_set_text(cast(c.GtkLabel, widget), text);
    }
}
