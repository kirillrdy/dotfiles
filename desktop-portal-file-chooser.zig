//! Native file portal dialogs, using the shell's existing GTK toolkit.
const std = @import("std");
const c = @import("gtk");
const cast = c.__zig.cast;
const eq = c.__zig.eq;
const child = c.g_variant_get_child_value;
fn text(value: ?*c.GVariant) [:0]const u8 {
    return std.mem.span(c.g_variant_get_string(value, null));
}
fn builder(signature: [*:0]const u8) *c.GVariantBuilder {
    return c.g_variant_builder_new(@ptrCast(signature)).?;
}
fn option(options: ?*c.GVariant, name: [*:0]const u8, signature: [*:0]const u8) !?*c.GVariant {
    const value = c.g_variant_lookup_value(options, name, null) orelse return null;
    if (!eq(std.mem.span(c.g_variant_get_type_string(value)), std.mem.span(signature))) {
        c.g_variant_unref(value);
        return error.InvalidFileChooserOption;
    }
    return value;
}
fn boolean(options: ?*c.GVariant, name: [*:0]const u8, fallback: bool) !bool {
    const value = try option(options, name, "b") orelse return fallback;
    defer c.g_variant_unref(value);
    return c.g_variant_get_boolean(value) != 0;
}
pub const Completion = *const fn (?*anyopaque, u32, ?*c.GVariant) void;
pub const Choice = struct { id: [:0]const u8, widget: *c.GtkWidget, boolean: bool };
pub const Dialog = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    window: *c.GtkWidget,
    options: *c.GVariant,
    method: enum { open, save, save_files },
    callback: Completion,
    data: ?*anyopaque,
    filters: std.ArrayList(*c.GtkFileFilter) = .empty,
    choices: std.ArrayList(Choice) = .empty,
    names: std.ArrayList([:0]const u8) = .empty,
    read_only: ?*c.GtkWidget = null,
    finished: bool = false,

    pub fn create(allocator: std.mem.Allocator, method: []const u8, parent: [:0]const u8, title: [:0]const u8, options: *c.GVariant, callback: Completion, data: ?*anyopaque) !*Dialog {
        if (c.gtk_init_check(null, null) == 0) return error.DisplayUnavailable;
        const kind: @FieldType(Dialog, "method") = if (eq(method, "OpenFile")) .open else if (eq(method, "SaveFile")) .save else if (eq(method, "SaveFiles")) .save_files else return error.InvalidFileChooserMethod;
        const action: c.GtkFileChooserAction = if (kind == .save) c.GTK_FILE_CHOOSER_ACTION_SAVE else if (kind == .save_files or try boolean(options, "directory", false)) c.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER else c.GTK_FILE_CHOOSER_ACTION_OPEN;
        const multiple = kind == .open and try boolean(options, "multiple", false);
        const modal = try boolean(options, "modal", true);
        const accept = try option(options, "accept_label", "s");
        defer if (accept != null) c.g_variant_unref(accept);
        const label: [*:0]const u8 = if (accept != null) text(accept).ptr else if (kind == .open) "_Open" else "_Save";
        const self = try allocator.create(Dialog);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .window = c.gtk_file_chooser_dialog_new(title, null, action, @as([*:0]const u8, "_Cancel"), c.GTK_RESPONSE_CANCEL, label, c.GTK_RESPONSE_OK, @as(?*anyopaque, null)),
            .options = c.g_variant_ref(options).?,
            .method = kind,
            .callback = callback,
            .data = data,
        };
        errdefer self.destroy();
        c.gtk_window_set_modal(cast(c.GtkWindow, self.window), @intFromBool(modal));
        c.gtk_dialog_set_default_response(cast(c.GtkDialog, self.window), c.GTK_RESPONSE_OK);
        c.gtk_file_chooser_set_select_multiple(self.chooser(), @intFromBool(multiple));
        c.gtk_file_chooser_set_do_overwrite_confirmation(self.chooser(), 1);
        c.gtk_file_chooser_set_local_only(self.chooser(), 1);
        try self.configureFilters();
        try self.configureChoices(action == c.GTK_FILE_CHOOSER_ACTION_OPEN);
        const folder = try option(options, "current_folder", "ay");
        defer if (folder != null) c.g_variant_unref(folder);
        if (folder != null) _ = c.gtk_file_chooser_set_current_folder(self.chooser(), try self.bytes(folder.?, false));
        if (kind == .save) {
            const name = try option(options, "current_name", "s");
            defer if (name != null) c.g_variant_unref(name);
            if (name != null) c.gtk_file_chooser_set_current_name(self.chooser(), text(name).ptr);
            const file = try option(options, "current_file", "ay");
            defer if (file != null) c.g_variant_unref(file);
            if (file != null) _ = c.gtk_file_chooser_select_filename(self.chooser(), try self.bytes(file.?, false));
        }
        if (kind == .save_files) {
            const files = try option(options, "files", "aay");
            defer if (files != null) c.g_variant_unref(files);
            if (files != null) {
                if (c.g_variant_n_children(files) > 256) return error.TooManyFiles;
                for (0..c.g_variant_n_children(files)) |index| {
                    const file = child(files, index);
                    defer c.g_variant_unref(file);
                    const name = try self.bytes(file.?, true);
                    try self.names.append(self.arena.allocator(), std.mem.span(name));
                }
            }
        }
        _ = c.g_signal_connect_data(self.window, "response", @ptrCast(&responded), self, null, 0);
        c.gtk_widget_show_all(self.window);
        c.gtk_window_present(cast(c.GtkWindow, self.window));
        @import("desktop-portal-window.zig").parentTo(self.window, allocator, parent);
        return self;
    }
    pub fn chooser(self: *Dialog) *c.GtkFileChooser {
        return cast(c.GtkFileChooser, self.window);
    }
    pub fn destroy(self: *Dialog) void {
        _ = c.g_signal_handlers_disconnect_matched(self.window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_widget_destroy(self.window);
        c.g_variant_unref(self.options);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    fn bytes(self: *Dialog, value: *c.GVariant, basename: bool) ![*:0]const u8 {
        var count: usize = 0;
        const ptr: [*]const u8 = @ptrCast(c.g_variant_get_fixed_array(value, &count, 1) orelse return error.InvalidFileName);
        if (count == 0 or count > 4096 or ptr[count - 1] != 0 or std.mem.indexOfScalar(u8, ptr[0 .. count - 1], 0) != null) return error.InvalidFileName;
        const path = ptr[0 .. count - 1];
        if (path.len == 0) return error.InvalidFileName;
        if (basename) {
            if (eq(path, ".") or eq(path, "..") or std.mem.indexOfScalar(u8, path, '/') != null) return error.InvalidFileName;
        } else if (!std.fs.path.isAbsolute(path)) return error.InvalidFileName;
        return (try self.arena.allocator().dupeSentinel(u8, path, 0)).ptr;
    }
    fn validateFilter(value: *c.GVariant) !void {
        const name = child(value, 0);
        defer c.g_variant_unref(name);
        if (text(name).len > 1024) return error.InvalidFileFilter;
        const rules = child(value, 1);
        defer c.g_variant_unref(rules);
        if (c.g_variant_n_children(rules) > 128) return error.InvalidFileFilter;
        for (0..c.g_variant_n_children(rules)) |index| {
            const rule = child(rules, index);
            defer c.g_variant_unref(rule);
            const kind = child(rule, 0);
            defer c.g_variant_unref(kind);
            const pattern = child(rule, 1);
            defer c.g_variant_unref(pattern);
            if (c.g_variant_get_uint32(kind) > 1 or text(pattern).len > 4096) return error.InvalidFileFilter;
        }
    }
    fn configureFilters(self: *Dialog) !void {
        const filters = try option(self.options, "filters", "a(sa(us))");
        defer if (filters != null) c.g_variant_unref(filters);
        if (filters != null) {
            if (c.g_variant_n_children(filters) > 64) return error.TooManyFileFilters;
            for (0..c.g_variant_n_children(filters)) |index| {
                const value = child(filters, index);
                defer c.g_variant_unref(value);
                try validateFilter(value.?);
                const filter = c.gtk_file_filter_new_from_gvariant(value) orelse return error.InvalidFileFilter;
                c.gtk_file_chooser_add_filter(self.chooser(), filter);
                try self.filters.append(self.arena.allocator(), filter);
            }
        }
        const current = try option(self.options, "current_filter", "(sa(us))");
        defer if (current != null) c.g_variant_unref(current);
        if (current) |value| {
            try validateFilter(value);
            const name = child(value, 0);
            defer c.g_variant_unref(name);
            if (self.filters.items.len == 0) {
                const filter = c.gtk_file_filter_new_from_gvariant(value) orelse return error.InvalidFileFilter;
                c.gtk_file_chooser_add_filter(self.chooser(), filter);
                try self.filters.append(self.arena.allocator(), filter);
                c.gtk_file_chooser_set_filter(self.chooser(), filter);
            } else {
                var found = false;
                for (self.filters.items) |filter| if (eq(std.mem.span(c.gtk_file_filter_get_name(filter)), text(name))) {
                    c.gtk_file_chooser_set_filter(self.chooser(), filter);
                    found = true;
                    break;
                };
                if (!found) return error.InvalidFileFilter;
            }
        }
    }
    fn configureChoices(self: *Dialog, readonly: bool) !void {
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
        c.gtk_file_chooser_set_extra_widget(self.chooser(), box);
        const choices = try option(self.options, "choices", "a(ssa(ss)s)");
        defer if (choices != null) c.g_variant_unref(choices);
        if (choices != null) {
            if (c.g_variant_n_children(choices) > 32) return error.TooManyFileChoices;
            for (0..c.g_variant_n_children(choices)) |index| {
                const value = child(choices, index);
                defer c.g_variant_unref(value);
                const id = child(value, 0);
                defer c.g_variant_unref(id);
                const label = child(value, 1);
                defer c.g_variant_unref(label);
                const items = child(value, 2);
                defer c.g_variant_unref(items);
                const selected = child(value, 3);
                defer c.g_variant_unref(selected);
                if (text(id).len == 0 or text(id).len > 128 or text(label).len > 4096 or c.g_variant_n_children(items) > 64) return error.InvalidFileChoice;
                for (self.choices.items) |choice| if (eq(choice.id, text(id))) return error.InvalidFileChoice;
                const choice_id = try self.arena.allocator().dupeSentinel(u8, text(id), 0);
                var widget: *c.GtkWidget = undefined;
                const is_boolean = c.g_variant_n_children(items) == 0;
                if (is_boolean) {
                    if (text(selected).len != 0 and !eq(text(selected), "true") and !eq(text(selected), "false")) return error.InvalidFileChoice;
                    widget = c.gtk_check_button_new_with_label(text(label));
                    c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, widget), @intFromBool(eq(text(selected), "true")));
                    c.gtk_box_pack_start(cast(c.GtkBox, box), widget, 0, 0, 0);
                } else {
                    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
                    c.gtk_box_pack_start(cast(c.GtkBox, box), row, 0, 0, 0);
                    const caption = c.gtk_label_new(text(label));
                    c.gtk_box_pack_start(cast(c.GtkBox, row), caption, 0, 0, 0);
                    widget = c.gtk_combo_box_text_new();
                    c.gtk_box_pack_start(cast(c.GtkBox, row), widget, 0, 0, 0);
                    var first: [:0]const u8 = "";
                    for (0..c.g_variant_n_children(items)) |i| {
                        const item = child(items, i);
                        defer c.g_variant_unref(item);
                        const option_id = child(item, 0);
                        defer c.g_variant_unref(option_id);
                        const option_label = child(item, 1);
                        defer c.g_variant_unref(option_label);
                        if (text(option_id).len == 0 or text(option_id).len > 128 or text(option_label).len > 4096) return error.InvalidFileChoice;
                        const owned_id = try self.arena.allocator().dupeSentinel(u8, text(option_id), 0);
                        if (i == 0) first = owned_id;
                        c.gtk_combo_box_text_append(cast(c.GtkComboBoxText, widget), owned_id, text(option_label));
                    }
                    const active = if (text(selected).len > 0) text(selected) else first;
                    if (c.gtk_combo_box_set_active_id(cast(c.GtkComboBox, widget), active) == 0) return error.InvalidFileChoice;
                }
                try self.choices.append(self.arena.allocator(), .{ .id = choice_id, .widget = widget, .boolean = is_boolean });
            }
        }
        if (readonly) {
            self.read_only = c.gtk_check_button_new_with_label("Open files read-only");
            c.gtk_box_pack_start(cast(c.GtkBox, box), self.read_only.?, 0, 0, 0);
        }
    }
    fn results(self: *Dialog) !?*c.GVariant {
        const out = builder("a{sv}");
        defer c.g_variant_builder_unref(out);
        const uris = builder("as");
        defer c.g_variant_builder_unref(uris);
        const selected = c.gtk_file_chooser_get_uris(self.chooser());
        defer {
            var node = selected;
            while (node != null) : (node = node.*.next) c.g_free(node.*.data);
            c.g_slist_free(selected);
        }
        if (selected == null) return error.NoSelection;
        if (self.method == .save_files) {
            const base_uri: [*:0]const u8 = @ptrCast(selected.*.data);
            const directory = c.g_file_new_for_uri(base_uri);
            defer c.g_object_unref(directory);
            var generated: std.ArrayList([:0]const u8) = .empty;
            for (self.names.items) |name| {
                var candidate = name;
                var suffix: usize = 0;
                while (true) {
                    const file = c.g_file_get_child(directory, candidate);
                    defer c.g_object_unref(file);
                    const uri = c.g_file_get_uri(file);
                    defer c.g_free(uri);
                    var duplicate = false;
                    for (generated.items) |previous| if (eq(previous, std.mem.span(uri))) {
                        duplicate = true;
                        break;
                    };
                    if (c.g_file_query_exists(file, null) == 0 and !duplicate) {
                        const owned = try self.arena.allocator().dupeSentinel(u8, std.mem.span(uri), 0);
                        try generated.append(self.arena.allocator(), owned);
                        c.g_variant_builder_add(uris, "s", uri);
                        break;
                    }
                    suffix += 1;
                    if (suffix > 10000) return error.TooManyExistingFiles;
                    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
                    const split = if (dot == 0) name.len else dot;
                    candidate = try std.fmt.allocPrintSentinel(self.arena.allocator(), "{s}({d}){s}", .{ name[0..split], suffix, name[split..] }, 0);
                }
            }
        } else {
            var node = selected;
            while (node != null) : (node = node.*.next) c.g_variant_builder_add(uris, "s", @as([*:0]const u8, @ptrCast(node.*.data)));
        }
        c.g_variant_builder_add(out, "{sv}", @as([*:0]const u8, "uris"), c.g_variant_builder_end(uris));
        const filter = c.gtk_file_chooser_get_filter(self.chooser());
        if (filter != null) {
            const value = c.g_variant_take_ref(c.gtk_file_filter_to_gvariant(filter));
            defer c.g_variant_unref(value);
            c.g_variant_builder_add(out, "{sv}", @as([*:0]const u8, "current_filter"), value);
        }
        const choices = builder("a(ss)");
        defer c.g_variant_builder_unref(choices);
        for (self.choices.items) |choice| {
            const value: [*:0]const u8 = if (choice.boolean) (if (c.gtk_toggle_button_get_active(cast(c.GtkToggleButton, choice.widget)) != 0) "true" else "false") else c.gtk_combo_box_get_active_id(cast(c.GtkComboBox, choice.widget));
            c.g_variant_builder_add(choices, "(ss)", choice.id.ptr, value);
        }
        c.g_variant_builder_add(out, "{sv}", @as([*:0]const u8, "choices"), c.g_variant_builder_end(choices));
        const writable = if (self.read_only) |widget| c.gtk_toggle_button_get_active(cast(c.GtkToggleButton, widget)) == 0 else true;
        c.g_variant_builder_add(out, "{sv}", @as([*:0]const u8, "writable"), c.g_variant_new("b", @as(c_int, @intFromBool(writable))));
        return c.g_variant_builder_end(out);
    }
    fn responded(_: *c.GtkDialog, response: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Dialog, data);
        if (self.finished) return;
        self.finished = true;
        c.gtk_widget_hide(self.window);
        var code: u32 = if (response == c.GTK_RESPONSE_OK or response == c.GTK_RESPONSE_ACCEPT) 0 else if (response == c.GTK_RESPONSE_CANCEL or response == c.GTK_RESPONSE_CLOSE or response == c.GTK_RESPONSE_DELETE_EVENT) 1 else 2;
        const result = if (code == 0) self.results() catch blk: {
            code = 2;
            break :blk c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "{sv}")), null, 0);
        } else c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "{sv}")), null, 0);
        self.callback(self.data, code, result);
    }
};
