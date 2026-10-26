//! OpenSSH's askpass protocol, with a native GTK password/confirmation dialog.
const std = @import("std");
pub const c = @import("gtk");
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
pub const Mode = enum {
    password,
    confirm,
    information,

    pub fn fromHint(hint: ?[]const u8) Mode {
        if (hint) |value| {
            if (std.mem.eql(u8, value, "confirm")) return .confirm;
            if (std.mem.eql(u8, value, "none")) return .information;
        }
        return .password;
    }
};

pub const Dialog = struct {
    window: *c.GtkWidget,
    prompt: *c.GtkWidget,
    entry: ?*c.GtkWidget,
    mode: Mode,
    accepted: bool = false,

    pub fn create(mode: Mode, text: [:0]const u8) Dialog {
        const window = c.gtk_dialog_new();
        c.gtk_window_set_title(cast(c.GtkWindow, window), "SSH Authentication");
        c.gtk_window_set_role(cast(c.GtkWindow, window), "desktop-askpass");
        c.gtk_window_set_type_hint(cast(c.GtkWindow, window), c.GDK_WINDOW_TYPE_HINT_DIALOG);
        c.gtk_window_set_icon_name(cast(c.GtkWindow, window), "dialog-password");
        c.gtk_window_set_modal(cast(c.GtkWindow, window), 1);
        c.gtk_window_set_keep_above(cast(c.GtkWindow, window), 1);
        c.gtk_window_set_resizable(cast(c.GtkWindow, window), 0);
        c.gtk_window_set_position(cast(c.GtkWindow, window), c.GTK_WIN_POS_CENTER);
        c.gtk_window_set_default_size(cast(c.GtkWindow, window), 460, -1);
        const content = c.gtk_dialog_get_content_area(cast(c.GtkDialog, window));
        c.gtk_container_set_border_width(cast(c.GtkContainer, content), 18);
        c.gtk_box_set_spacing(cast(c.GtkBox, content), 14);
        const prompt = c.gtk_label_new(text.ptr);
        // Prompts can contain hostnames, paths or angle brackets. Treat them
        // as plain text, never GTK markup or a printf format string.
        c.gtk_label_set_xalign(cast(c.GtkLabel, prompt), 0);
        c.gtk_label_set_line_wrap(cast(c.GtkLabel, prompt), 1);
        c.gtk_label_set_max_width_chars(cast(c.GtkLabel, prompt), 60);
        c.gtk_box_pack_start(cast(c.GtkBox, content), prompt, 0, 0, 0);
        var entry: ?*c.GtkWidget = null;
        if (mode == .password) {
            entry = c.gtk_entry_new();
            c.gtk_entry_set_visibility(cast(c.GtkEntry, entry.?), 0);
            c.gtk_entry_set_input_purpose(cast(c.GtkEntry, entry.?), c.GTK_INPUT_PURPOSE_PASSWORD);
            c.gtk_entry_set_activates_default(cast(c.GtkEntry, entry.?), 1);
            c.gtk_box_pack_start(cast(c.GtkBox, content), entry.?, 0, 0, 0);
        }
        if (mode != .information) _ = c.gtk_dialog_add_button(cast(c.GtkDialog, window), if (mode == .confirm) "Deny" else "Cancel", c.GTK_RESPONSE_CANCEL);
        _ = c.gtk_dialog_add_button(cast(c.GtkDialog, window), switch (mode) {
            .password => "Unlock",
            .confirm => "Allow",
            .information => "Close",
        }, c.GTK_RESPONSE_OK);
        // A confirmation should require an explicit affirmative choice.
        c.gtk_dialog_set_default_response(cast(c.GtkDialog, window), if (mode == .confirm) c.GTK_RESPONSE_CANCEL else c.GTK_RESPONSE_OK);
        c.gtk_widget_show_all(window);
        if (entry) |widget| c.gtk_widget_grab_focus(widget);
        return .{ .window = window, .prompt = prompt, .entry = entry, .mode = mode };
    }
    pub fn destroy(self: *Dialog) void {
        self.clear();
        c.gtk_widget_destroy(self.window);
    }
    fn clear(self: *Dialog) void {
        if (self.entry) |widget| c.gtk_entry_set_text(cast(c.GtkEntry, widget), "");
    }
    fn cancel(data: c.gpointer) callconv(.c) c.gboolean {
        const self: *Dialog = @ptrCast(@alignCast(data));
        c.gtk_dialog_response(cast(c.GtkDialog, self.window), c.GTK_RESPONSE_CANCEL);
        return 1; // Removed explicitly when the dialog's nested loop exits.
    }
    pub fn run(self: *Dialog) void {
        const term = c.g_unix_signal_add(c.SIGTERM, &cancel, self);
        defer _ = c.g_source_remove(term);
        const interrupt = c.g_unix_signal_add(c.SIGINT, &cancel, self);
        defer _ = c.g_source_remove(interrupt);
        c.gtk_window_present(cast(c.GtkWindow, self.window));
        self.accepted = c.gtk_dialog_run(cast(c.GtkDialog, self.window)) == c.GTK_RESPONSE_OK;
    }
    /// Nothing goes to stdout unless explicitly accepted. The caller must
    /// propagate the status: OpenSSH treats a nonzero exit as cancellation.
    pub fn writeAnswer(self: *Dialog, io: std.Io, output: std.Io.File) !u8 {
        defer self.clear();
        if (!self.accepted) return 1;
        switch (self.mode) {
            .password => {
                const text = c.gtk_entry_get_text(cast(c.GtkEntry, self.entry.?));
                try output.writeStreamingAll(io, std.mem.span(text));
                try output.writeStreamingAll(io, "\n");
            },
            .confirm => try output.writeStreamingAll(io, "yes\n"),
            .information => {},
        }
        return 0;
    }
};

pub fn main(init: std.process.Init) void {
    const status = run(init) catch 1;
    if (status != 0) std.process.exit(status);
}
fn run(init: std.process.Init) !u8 {
    // Passwords should not appear in a core dump or another process's ptrace
    // view. No password is copied into argv, an environment variable or a file.
    if (c.prctl(c.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return 1;
    if (c.gtk_init_check(null, null) == 0) return 1;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    const text = try arena.allocator().dupeSentinel(u8, if (args.len > 1) args[1] else "Enter your SSH passphrase:", 0);
    const hint = c.g_getenv("SSH_ASKPASS_PROMPT");
    var dialog = Dialog.create(Mode.fromHint(if (hint) |h| std.mem.span(h) else null), text);
    defer dialog.destroy();
    dialog.run();
    return dialog.writeAnswer(init.io, std.Io.File.stdout());
}
