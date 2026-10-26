//! PolicyKit authentication agent with a native GNOME-style GTK dialog.
const std = @import("std");
pub const c = @import("gtk");
const libc = @import("libc");

fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}

fn isUnixUser(id: *c.PolkitIdentity) bool {
    return c.g_type_check_instance_is_a(cast(c.GTypeInstance, id), c.polkit_unix_user_get_type()) != 0;
}

const Listener = extern struct {
    parent: c.PolkitAgentListener,
};

const ListenerClass = extern struct {
    parent: c.PolkitAgentListenerClass,
};

fn listenerClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    const parent: *c.PolkitAgentListenerClass = @ptrCast(@alignCast(klass));
    parent.initiate_authentication = &initiateAuth;
    parent.initiate_authentication_finish = &finishAuth;
}

fn listenerInstanceInit(_: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {}

fn getListenerType() c.GType {
    const S = struct {
        var gtype: c.GType = 0;
    };
    if (S.gtype == 0) {
        S.gtype = c.g_type_register_static_simple(
            c.polkit_agent_listener_get_type(),
            "DesktopPolkitListener",
            @sizeOf(ListenerClass),
            &listenerClassInit,
            @sizeOf(Listener),
            &listenerInstanceInit,
            0,
        );
    }
    return S.gtype;
}

fn createListener() *c.PolkitAgentListener {
    return @ptrCast(@alignCast(c.g_object_new(getListenerType(), null)));
}

pub const Dialog = struct {
    window: *c.GtkWidget,
    prompt: *c.GtkWidget,
    action_label: ?*c.GtkWidget,
    user_label: ?*c.GtkWidget,
    entry: *c.GtkWidget,
    error_label: *c.GtkWidget,
    auth_button: *c.GtkWidget,
    session: ?*c.PolkitAgentSession = null,
    task: ?*c.GTask = null,
    cancellable: ?*c.GCancellable = null,
    cancel_id: c.gulong = 0,
    cookie: ?[:0]const u8 = null,
    identity: ?*c.PolkitIdentity = null,
    accepted: bool = false,
    cancelled: bool = false,
    tries: u32 = 0,

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
            const text = std.fmt.bufPrintSentinel(&buf, "<span size=\"smaller\" color=\"#949497\">Action: {s}</span>", .{action}, 0) catch action;
            c.gtk_label_set_markup(cast(c.GtkLabel, action_label.?), text.ptr);
            c.gtk_label_set_xalign(cast(c.GtkLabel, action_label.?), 0);
            c.gtk_box_pack_start(cast(c.GtkBox, content), action_label.?, 0, 0, 0);
        }

        var user_label: ?*c.GtkWidget = null;
        if (user) |username| {
            user_label = c.gtk_label_new(null);
            var buf: [256:0]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "Password for <b>{s}</b>:", .{username}, 0) catch "Password:";
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
        const text = std.fmt.bufPrintSentinel(&buf, "<span color=\"#ef4444\" weight=\"bold\">{s}</span>", .{message}, 0) catch return;
        c.gtk_label_set_markup(cast(c.GtkLabel, self.error_label), text.ptr);
        c.gtk_widget_show(self.error_label);
    }

    pub fn clear(self: *Dialog) void {
        c.gtk_entry_set_text(cast(c.GtkEntry, self.entry), "");
    }

    pub fn destroy(self: *Dialog) void {
        self.clear();
        if (self.cancellable) |canc| {
            if (self.cancel_id != 0) c.g_signal_handler_disconnect(cast(c.GObject, canc), self.cancel_id);
            c.g_object_unref(canc);
            self.cancellable = null;
            self.cancel_id = 0;
        }
        if (self.session) |sess| {
            c.g_object_unref(sess);
            self.session = null;
        }
        if (self.identity) |id| {
            c.g_object_unref(id);
            self.identity = null;
        }
        c.gtk_widget_destroy(self.window);
    }

    pub fn finishSuccess(self: *Dialog) void {
        self.accepted = true;
        if (self.task) |task| {
            c.g_task_return_boolean(task, 1);
            c.g_object_unref(task);
            self.task = null;
        }
        self.destroy();
    }

    pub fn finishCancel(self: *Dialog) void {
        self.cancelled = true;
        if (self.session) |sess| c.polkit_agent_session_cancel(sess);
        if (self.task) |task| {
            c.g_task_return_new_error(task, c.polkit_error_quark(), c.POLKIT_ERROR_CANCELLED, "Authentication was cancelled");
            c.g_object_unref(task);
            self.task = null;
        }
        self.destroy();
    }

    pub fn restartSession(self: *Dialog) void {
        if (self.session) |sess| {
            c.g_object_unref(sess);
            self.session = null;
        }
        if (self.identity != null and self.cookie != null) {
            self.session = c.polkit_agent_session_new(self.identity.?, self.cookie.?.ptr);
            self.connectSessionSignals();
            c.polkit_agent_session_initiate(self.session.?);
        }
    }

    fn onSessionRequest(_: ?*c.PolkitAgentSession, _: [*c]const u8, echo_on: c.gboolean, data: c.gpointer) callconv(.c) void {
        const self: *Dialog = @ptrCast(@alignCast(data));
        c.gtk_entry_set_visibility(cast(c.GtkEntry, self.entry), echo_on);
        c.gtk_widget_set_sensitive(self.entry, 1);
        c.gtk_widget_set_sensitive(self.auth_button, 1);
        c.gtk_widget_show_all(self.window);
        c.gtk_window_present(cast(c.GtkWindow, self.window));
        c.gtk_widget_grab_focus(self.entry);
    }

    fn onSessionShowError(_: ?*c.PolkitAgentSession, msg: [*c]const u8, data: c.gpointer) callconv(.c) void {
        const self: *Dialog = @ptrCast(@alignCast(data));
        if (msg != null) self.setError(std.mem.span(msg));
        self.clear();
        c.gtk_widget_set_sensitive(self.entry, 1);
        c.gtk_widget_set_sensitive(self.auth_button, 1);
        c.gtk_widget_grab_focus(self.entry);
    }

    fn onSessionShowInfo(_: ?*c.PolkitAgentSession, msg: [*c]const u8, data: c.gpointer) callconv(.c) void {
        const self: *Dialog = @ptrCast(@alignCast(data));
        if (msg != null) {
            var buf: [512:0]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "<span color=\"#949497\">{s}</span>", .{std.mem.span(msg)}, 0) catch return;
            c.gtk_label_set_markup(cast(c.GtkLabel, self.error_label), text.ptr);
            c.gtk_widget_show(self.error_label);
        }
    }

    fn onSessionCompleted(_: ?*c.PolkitAgentSession, gained_authorization: c.gboolean, data: c.gpointer) callconv(.c) void {
        const self: *Dialog = @ptrCast(@alignCast(data));
        if (gained_authorization != 0) {
            self.finishSuccess();
        } else if (!self.cancelled and self.tries < 3) {
            self.setError("Authentication failed. Please try again.");
            self.clear();
            self.restartSession();
        } else {
            self.finishCancel();
        }
    }

    fn connectSessionSignals(self: *Dialog) void {
        if (self.session) |sess| {
            _ = c.g_signal_connect_data(cast(c.GObject, sess), "request", @ptrCast(&onSessionRequest), self, null, 0);
            _ = c.g_signal_connect_data(cast(c.GObject, sess), "show-error", @ptrCast(&onSessionShowError), self, null, 0);
            _ = c.g_signal_connect_data(cast(c.GObject, sess), "show-info", @ptrCast(&onSessionShowInfo), self, null, 0);
            _ = c.g_signal_connect_data(cast(c.GObject, sess), "completed", @ptrCast(&onSessionCompleted), self, null, 0);
        }
    }

    fn onResponse(_: *c.GtkDialog, response_id: c_int, data: c.gpointer) callconv(.c) void {
        const self: *Dialog = @ptrCast(@alignCast(data));
        if (response_id == c.GTK_RESPONSE_OK) {
            const pass = c.gtk_entry_get_text(cast(c.GtkEntry, self.entry));
            c.gtk_widget_set_sensitive(self.entry, 0);
            c.gtk_widget_set_sensitive(self.auth_button, 0);
            self.tries += 1;
            if (self.session) |sess| {
                c.polkit_agent_session_response(sess, pass);
            }
            self.clear();
        } else {
            self.finishCancel();
        }
    }

    fn onCancellableCancelled(_: *c.GCancellable, data: c.gpointer) callconv(.c) void {
        const self: *Dialog = @ptrCast(@alignCast(data));
        self.finishCancel();
    }
};

var active_dialog: ?*Dialog = null;

fn initiateAuth(
    listener: ?*c.PolkitAgentListener,
    action_id: [*c]const u8,
    message: [*c]const u8,
    icon_name: [*c]const u8,
    _: ?*c.PolkitDetails,
    cookie: [*c]const u8,
    identities: ?*c.GList,
    cancellable: ?*c.GCancellable,
    callback: c.GAsyncReadyCallback,
    user_data: c.gpointer,
) callconv(.c) void {
    const task = c.g_task_new(cast(c.GObject, listener), cancellable, callback, user_data);

    if (active_dialog != null) {
        c.g_task_return_new_error(task, c.polkit_error_quark(), c.POLKIT_ERROR_FAILED, "An authentication request is already active");
        c.g_object_unref(task);
        return;
    }

    var selected_identity: ?*c.PolkitIdentity = null;
    var user_buffer: [128:0]u8 = undefined;
    var username: ?[:0]const u8 = null;

    if (identities) |list| {
        const current_uid = libc.getuid();
        var curr: ?*c.GList = list;
        while (curr) |node| : (curr = node.*.next) {
            const id: *c.PolkitIdentity = cast(c.PolkitIdentity, node.*.data);
            if (isUnixUser(id)) {
                const unix_user: *c.PolkitUnixUser = @ptrCast(@alignCast(id));
                const uid = c.polkit_unix_user_get_uid(unix_user);
                if (uid >= 0 and @as(libc.__uid_t, @intCast(uid)) == current_uid) {
                    selected_identity = id;
                    break;
                }
            }
        }
        if (selected_identity == null and list.*.data != null) {
            selected_identity = cast(c.PolkitIdentity, list.*.data);
        }
    }

    if (selected_identity) |id| {
        if (isUnixUser(id)) {
            const unix_user: *c.PolkitUnixUser = @ptrCast(@alignCast(id));
            const uid = c.polkit_unix_user_get_uid(unix_user);
            if (uid >= 0) {
                if (libc.getpwuid(@intCast(uid))) |pwd| {
                    const name = std.mem.span(pwd.*.pw_name);
                    if (name.len < user_buffer.len) {
                        @memcpy(user_buffer[0..name.len], name);
                        user_buffer[name.len] = 0;
                        username = user_buffer[0..name.len :0];
                    }
                }
            }
        }
    }

    const alloc = std.heap.page_allocator;
    const dialog_ptr = alloc.create(Dialog) catch {
        c.g_task_return_new_error(task, c.polkit_error_quark(), c.POLKIT_ERROR_FAILED, "Out of memory");
        c.g_object_unref(task);
        return;
    };

    const action_span = if (action_id != null) std.mem.span(action_id) else null;
    const msg_span = if (message != null) std.mem.span(message) else "Authentication is required to proceed.";
    const icon_span = if (icon_name != null) std.mem.span(icon_name) else null;

    dialog_ptr.* = Dialog.create(
        action_span,
        msg_span,
        username,
        icon_span,
    );
    dialog_ptr.task = task;
    if (selected_identity) |id| dialog_ptr.identity = cast(c.PolkitIdentity, c.g_object_ref(cast(c.GObject, id)));
    if (cookie != null) dialog_ptr.cookie = alloc.dupeSentinel(u8, std.mem.span(cookie), 0) catch null;

    if (cancellable) |canc| {
        dialog_ptr.cancellable = cast(c.GCancellable, c.g_object_ref(cast(c.GObject, canc)));
        dialog_ptr.cancel_id = c.g_signal_connect_data(cast(c.GObject, canc), "cancelled", @ptrCast(&Dialog.onCancellableCancelled), dialog_ptr, null, 0);
    }

    _ = c.g_signal_connect_data(cast(c.GObject, dialog_ptr.window), "response", @ptrCast(&Dialog.onResponse), dialog_ptr, null, 0);

    active_dialog = dialog_ptr;
    dialog_ptr.restartSession();
}

fn finishAuth(_: ?*c.PolkitAgentListener, res: ?*c.GAsyncResult, err: [*c]?*c.GError) callconv(.c) c.gboolean {
    if (active_dialog) |d| {
        if (d.cookie) |cook| std.heap.page_allocator.free(cook);
        std.heap.page_allocator.destroy(d);
        active_dialog = null;
    }
    return c.g_task_propagate_boolean(cast(c.GTask, res), err);
}

fn onSignal(_: c.gpointer) callconv(.c) c.gboolean {
    if (active_dialog) |d| d.finishCancel();
    c.gtk_main_quit();
    return 1;
}

pub fn main(init: std.process.Init) void {
    const status = run(init) catch 1;
    if (status != 0) std.process.exit(status);
}

fn run(init: std.process.Init) !u8 {
    _ = init;
    if (libc.prctl(libc.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return 1;
    if (c.gtk_init_check(null, null) == 0) return 1;
    var service = Service.init() catch return 1;
    defer service.deinit();
    const term = c.g_unix_signal_add(libc.SIGTERM, &onSignal, null);
    const interrupt = c.g_unix_signal_add(libc.SIGINT, &onSignal, null);
    defer _ = c.g_source_remove(term);
    defer _ = c.g_source_remove(interrupt);
    c.gtk_main();
    return 0;
}

pub const Service = struct {
    listener: *c.PolkitAgentListener,
    handle: c.gpointer,
    pub fn init() !Service {
        var err: ?*c.GError = null;
        defer c.g_clear_error(&err);
        const authority = c.polkit_authority_get_sync(null, &err);
        if (authority == null) {
            if (err) |e| c.g_printerr("Failed to connect to PolicyKit authority: %s\n", e.*.message);
            return error.PolicyKitUnavailable;
        }
        defer c.g_object_unref(authority);

        c.g_clear_error(&err);
        var session: ?*c.PolkitSubject = c.polkit_unix_session_new_for_process_sync(libc.getpid(), null, &err);
        if (session == null) {
            if (c.g_getenv("XDG_SESSION_ID")) |sid| {
                session = c.polkit_unix_session_new(sid);
            }
        }
        if (session == null) {
            session = c.polkit_unix_process_new_for_owner(libc.getpid(), 0, @intCast(libc.getuid()));
        }
        defer if (session) |s| c.g_object_unref(s);

        const listener = createListener();
        errdefer c.g_object_unref(listener);

        c.g_clear_error(&err);
        const handle = c.polkit_agent_listener_register(
            listener,
            c.POLKIT_AGENT_REGISTER_FLAGS_NONE,
            session,
            "/org/dotfiles/PolicyKit1/AuthenticationAgent",
            null,
            &err,
        );
        if (handle == null) {
            if (err) |e| c.g_printerr("Failed to register authentication agent: %s\n", e.*.message);
            return error.PolicyKitUnavailable;
        }
        return .{ .listener = listener, .handle = handle.? };
    }
    pub fn deinit(self: *Service) void {
        c.polkit_agent_listener_unregister(self.handle);
        if (active_dialog) |dialog| dialog.finishCancel();
        c.g_object_unref(self.listener);
    }
};
