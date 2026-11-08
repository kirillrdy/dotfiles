//! Portal file chooser with native Zig form controls and asynchronous GIO enumeration.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const cast = c.__zig.cast;
const eq = c.__zig.eq;
const child = c.g_variant_get_child_value;
fn text(value: ?*c.GVariant) [:0]const u8 {
    return std.mem.span(c.g_variant_get_string(value, null));
}
fn builder(signature: [*:0]const u8) *c.GVariantBuilder {
    return c.g_variant_builder_new(@ptrCast(signature)).?;
}
const Options = @import("desktop-portal-options.zig").Options(error.InvalidFileChooserOption);
const option = Options.get;
const boolean = Options.boolean;
const form = @import("desktop-form.zig");
const files = @import("desktop-file-list.zig");
pub const Completion = *const fn (?*anyopaque, u32, ?*c.GVariant) void;
pub const Choice = struct { id: [:0]const u8, item: usize, boolean: bool };
pub const Filter = struct { value: *c.GVariant, id: [:0]const u8, name: [:0]const u8, rules: []const files.Rule };
const Row = struct { item: usize, entry: usize };
pub const Dialog = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    window: *c.GtkWidget,
    ui: *form.Form,
    options: *c.GVariant,
    method: enum { open, save, save_files },
    directory: bool,
    multiple: bool,
    callback: Completion,
    data: ?*anyopaque,
    filters: std.ArrayList(Filter) = .empty,
    choices: std.ArrayList(Choice) = .empty,
    names: std.ArrayList([:0]const u8) = .empty,
    rows: std.ArrayList(Row) = .empty,
    read_only: ?usize = null,
    filter_item: ?usize = null,
    name_item: ?usize = null,
    path_item: usize = 0,
    up_item: usize = 0,
    go_item: usize = 0,
    hidden_item: usize = 0,
    previous_item: usize = 0,
    next_item: usize = 0,
    message_item: usize = 0,
    cancel_item: usize = 0,
    accept_item: usize = 0,
    dynamic_start: usize = 0,
    page: usize = 0,
    folder: [:0]const u8 = "",
    listing: ?*files.Scan = null,
    pending: ?*files.Scan = null,
    pending_count: usize = 0,
    initial_file: ?[:0]const u8 = null,
    accept_after_scan: bool = false,
    overwrite: ?[:0]const u8 = null,
    finished: bool = false,
    dead: bool = false,
    const page_size = 32;

    pub fn create(allocator: std.mem.Allocator, method: []const u8, parent: [:0]const u8, title: [:0]const u8, options: *c.GVariant, callback: Completion, data: ?*anyopaque) !*Dialog {
        if (c.gtk_init_check(null, null) == 0) return error.DisplayUnavailable;
        const kind: @FieldType(Dialog, "method") = if (eq(method, "OpenFile")) .open else if (eq(method, "SaveFile")) .save else if (eq(method, "SaveFiles")) .save_files else return error.InvalidFileChooserMethod;
        const self = try allocator.create(Dialog);
        errdefer allocator.destroy(self);
        const ui = try form.Form.create(title, self, &action, &changed);
        self.* = .{ .allocator = allocator, .arena = .init(allocator), .window = ui.window, .ui = ui, .options = c.g_variant_ref(options).?, .method = kind, .directory = kind == .save_files, .multiple = false, .callback = callback, .data = data };
        errdefer {
            ui.deinit();
            self.freeResources();
        }
        self.directory = kind == .save_files or (kind == .open and try boolean(options, "directory", false));
        self.multiple = kind == .open and try boolean(options, "multiple", false);
        c.gtk_window_set_modal(cast(c.GtkWindow, self.window), @intFromBool(try boolean(options, "modal", true)));
        self.path_item = try ui.add(.entry, "Folder", "Enter an absolute path, then choose Go", false);
        self.up_item = try ui.add(.button, "Parent folder", "", false);
        self.go_item = try ui.add(.button, "Go", "", false);
        ui.pair(self.up_item, self.go_item);
        self.hidden_item = try ui.add(.toggle, "Show hidden files", "", false);
        if (kind == .save) {
            self.name_item = try ui.add(.entry, "File name", "", false);
            const name = try option(options, "current_name", "s");
            defer if (name != null) c.g_variant_unref(name);
            if (name != null) try ui.setText(self.name_item.?, text(name));
        }
        try self.configureFilters();
        try self.configureChoices(kind == .open and !self.directory);
        self.previous_item = try ui.add(.button, "Previous files", "", false);
        self.next_item = try ui.add(.button, "Next files", "", false);
        ui.pair(self.previous_item, self.next_item);
        self.message_item = try ui.addPinned(.label, "Loading folder…");
        self.cancel_item = try ui.addPinned(.button, "Cancel");
        const accept_label = try option(options, "accept_label", "s");
        defer if (accept_label != null) c.g_variant_unref(accept_label);
        self.accept_item = try ui.addPinned(.button, if (accept_label != null) text(accept_label) else if (kind == .open) "Open" else "Save");
        self.dynamic_start = ui.items.items.len;
        const folder = try option(options, "current_folder", "ay");
        defer if (folder != null) c.g_variant_unref(folder);
        var initial: [:0]const u8 = if (folder != null) std.mem.span(try self.bytes(folder.?, false)) else std.mem.span(c.g_get_home_dir());
        if (kind == .save) {
            const file = try option(options, "current_file", "ay");
            defer if (file != null) c.g_variant_unref(file);
            if (file != null) {
                const path = std.mem.span(try self.bytes(file.?, false));
                initial = try self.arena.allocator().dupeSentinel(u8, std.fs.path.dirname(path) orelse "/", 0);
                try ui.setText(self.name_item.?, try self.arena.allocator().dupeSentinel(u8, std.fs.path.basename(path), 0));
            }
        }
        if (kind == .save_files) {
            const names = try option(options, "files", "aay");
            defer if (names != null) c.g_variant_unref(names);
            if (names != null) {
                if (c.g_variant_n_children(names) > 256) return error.TooManyFiles;
                for (0..c.g_variant_n_children(names)) |index| {
                    const name = child(names, index);
                    defer c.g_variant_unref(name);
                    try self.names.append(self.arena.allocator(), std.mem.span(try self.bytes(name.?, true)));
                }
            }
        }
        // Start asynchronous work only after all fallible option validation.
        try self.navigate(initial);
        _ = c.g_signal_connect_data(self.window, "destroy", @ptrCast(&closed), self, null, 0);
        ui.shortcut = &key;
        ui.show();
        ui.focusItem(self.path_item);
        c.gtk_window_present(cast(c.GtkWindow, self.window));
        c.__zig.parentTo(self.window, allocator, parent);
        return self;
    }
    fn freeResources(self: *Dialog) void {
        if (self.listing) |listing| listing.destroy();
        for (self.filters.items) |filter| c.g_variant_unref(filter.value);
        c.g_variant_unref(self.options);
        self.arena.deinit();
    }
    pub fn destroy(self: *Dialog) void {
        if (self.dead) return;
        self.dead = true;
        if (self.pending) |pending| pending.cancel();
        _ = c.g_signal_handlers_disconnect_matched(self.window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        self.ui.deinit();
        if (self.pending_count == 0) self.release();
    }
    fn release(self: *Dialog) void {
        self.freeResources();
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
    fn addFilter(self: *Dialog, value: *c.GVariant) !void {
        try validateFilter(value);
        const a = self.arena.allocator();
        const name = child(value, 0);
        defer c.g_variant_unref(name);
        const rules = child(value, 1);
        defer c.g_variant_unref(rules);
        var parsed: std.ArrayList(files.Rule) = .empty;
        for (0..c.g_variant_n_children(rules)) |index| {
            const rule = child(rules, index);
            defer c.g_variant_unref(rule);
            const kind = child(rule, 0);
            defer c.g_variant_unref(kind);
            const pattern = child(rule, 1);
            defer c.g_variant_unref(pattern);
            try parsed.append(a, .{ .mime = c.g_variant_get_uint32(kind) == 1, .pattern = try a.dupeSentinel(u8, text(pattern), 0) });
        }
        const filter: Filter = .{ .value = value, .id = try std.fmt.allocPrintSentinel(a, "{d}", .{self.filters.items.len}, 0), .name = try a.dupeSentinel(u8, text(name), 0), .rules = parsed.items };
        try self.filters.append(a, filter);
        _ = c.g_variant_ref(value);
    }
    fn configureFilters(self: *Dialog) !void {
        const filters = try option(self.options, "filters", "a(sa(us))");
        defer if (filters != null) c.g_variant_unref(filters);
        if (filters != null) {
            if (c.g_variant_n_children(filters) > 64) return error.TooManyFileFilters;
            for (0..c.g_variant_n_children(filters)) |index| {
                const value = child(filters, index);
                defer c.g_variant_unref(value);
                try self.addFilter(value.?);
            }
        }
        const current = try option(self.options, "current_filter", "(sa(us))");
        defer if (current != null) c.g_variant_unref(current);
        var selected: usize = 0;
        if (current) |value| {
            try validateFilter(value);
            if (self.filters.items.len == 0) try self.addFilter(value) else {
                const name = child(value, 0);
                defer c.g_variant_unref(name);
                var found = false;
                for (self.filters.items, 0..) |filter, index| if (eq(filter.name, text(name))) {
                    selected = index;
                    found = true;
                    break;
                };
                if (!found) return error.InvalidFileFilter;
            }
        }
        if (self.filters.items.len > 0) {
            const id = try self.ui.add(.choice, "File type", "", false);
            self.filter_item = id;
            var options: std.ArrayList(form.Option) = .empty;
            for (self.filters.items) |filter| try options.append(self.arena.allocator(), .{ .id = filter.id, .label = filter.name });
            try self.ui.setOptions(id, options.items, true);
            _ = self.ui.select(id, self.filters.items[selected].id);
        }
    }
    pub fn currentFilter(self: *const Dialog) ?Filter {
        const item = self.filter_item orelse return null;
        return self.filters.items[self.ui.get(item).selected.?];
    }
    fn configureChoices(self: *Dialog, readonly: bool) !void {
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
                const is_boolean = c.g_variant_n_children(items) == 0;
                const item = try self.ui.add(if (is_boolean) .toggle else .choice, text(label), "", false);
                if (is_boolean) {
                    if (text(selected).len != 0 and !eq(text(selected), "true") and !eq(text(selected), "false")) return error.InvalidFileChoice;
                    self.ui.setChecked(item, eq(text(selected), "true"));
                } else {
                    var options: std.ArrayList(form.Option) = .empty;
                    for (0..c.g_variant_n_children(items)) |i| {
                        const entry = child(items, i);
                        defer c.g_variant_unref(entry);
                        const option_id = child(entry, 0);
                        defer c.g_variant_unref(option_id);
                        const option_label = child(entry, 1);
                        defer c.g_variant_unref(option_label);
                        if (text(option_id).len == 0 or text(option_id).len > 128 or text(option_label).len > 4096) return error.InvalidFileChoice;
                        const owned_id = try self.arena.allocator().dupeSentinel(u8, text(option_id), 0);
                        for (options.items) |previous| if (eq(previous.id, owned_id)) return error.InvalidFileChoice;
                        try options.append(self.arena.allocator(), .{ .id = owned_id, .label = try self.arena.allocator().dupeSentinel(u8, text(option_label), 0) });
                    }
                    try self.ui.setOptions(item, options.items, true);
                    if (text(selected).len != 0 and !self.ui.select(item, text(selected))) return error.InvalidFileChoice;
                }
                try self.choices.append(self.arena.allocator(), .{ .id = try self.arena.allocator().dupeSentinel(u8, text(id), 0), .item = item, .boolean = is_boolean });
            }
        }
        if (readonly) self.read_only = try self.ui.add(.toggle, "Open files read-only", "", false);
    }
    fn message(self: *Dialog, value: [:0]const u8) void {
        self.ui.setText(self.message_item, value) catch {};
    }
    pub fn navigate(self: *Dialog, path: [:0]const u8) !void {
        if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidFileName;
        const copy = try self.arena.allocator().dupeSentinel(u8, path, 0);
        try self.ui.setText(self.path_item, if (std.unicode.utf8ValidateSlice(copy)) copy else "");
        const scan = try files.Scan.start(self.allocator, copy, self, &scanned);
        if (self.pending) |previous| previous.cancel();
        self.pending = scan;
        self.pending_count += 1;
        self.folder = copy;
        self.page = 0;
        self.overwrite = null;
        self.initial_file = null;
        self.accept_after_scan = false;
        self.rows.clearRetainingCapacity();
        self.ui.truncate(self.dynamic_start);
        if (self.listing) |listing| listing.destroy();
        self.listing = null;
        self.ui.get(self.accept_item).enabled = false;
        self.message("Loading folder…");
    }
    fn scanned(ptr: ?*anyopaque, scan: *files.Scan, failure: ?anyerror) void {
        const self = cast(Dialog, ptr);
        self.pending_count -= 1;
        if (self.dead or self.pending != scan) {
            scan.destroy();
            if (self.dead and self.pending_count == 0) self.release();
            return;
        }
        self.pending = null;
        if (failure) |err| {
            scan.destroy();
            self.message(if (err == error.DirectoryTooLarge) "Folder has too many files. Enter a more specific folder." else "Unable to read this folder. Check its path and permissions.");
            return;
        }
        self.listing = scan;
        if (self.initial_file) |name| {
            for (scan.entries.items) |*entry| if (eq(entry.name, name)) {
                entry.selected = true;
                break;
            };
            self.initial_file = null;
        }
        self.renderRows() catch {
            self.message("Unable to display files.");
        };
        if (self.accept_after_scan) {
            self.accept_after_scan = false;
            self.accept();
        }
    }
    fn visible(self: *Dialog, entry: files.Entry) bool {
        if (entry.hidden and !self.ui.get(self.hidden_item).checked) return false;
        if (self.directory and !entry.directory) return false;
        return files.matches(entry, if (self.currentFilter()) |filter| filter.rules else &.{});
    }
    fn renderRows(self: *Dialog) !void {
        self.rows.clearRetainingCapacity();
        self.ui.truncate(self.dynamic_start);
        const listing = self.listing orelse return;
        var count: usize = 0;
        for (listing.entries.items, 0..) |entry, index| {
            if (!self.visible(entry)) continue;
            const ordinal = count;
            count += 1;
            if (ordinal < self.page * page_size or ordinal >= (self.page + 1) * page_size) continue;
            const a = self.allocator;
            const label = try std.fmt.allocPrintSentinel(a, "{s}{s}", .{ if (entry.directory) "Folder: " else "", entry.label }, 0);
            defer a.free(label);
            if (entry.directory and self.directory and self.multiple) {
                const select = try self.ui.add(.toggle, entry.label, "", false);
                self.ui.setChecked(select, entry.selected);
                try self.rows.append(self.arena.allocator(), .{ .item = select, .entry = index });
            }
            const id = try self.ui.add(if (entry.directory) .button else .toggle, label, "", false);
            self.ui.setChecked(id, entry.selected);
            try self.rows.append(self.arena.allocator(), .{ .item = id, .entry = index });
        }
        self.ui.get(self.previous_item).enabled = self.page > 0;
        self.ui.get(self.next_item).enabled = count > (self.page + 1) * page_size;
        self.ui.get(self.accept_item).enabled = true;
        const status = try std.fmt.allocPrintSentinel(self.allocator, "{d} items · page {d}. {s}", .{ count, self.page + 1, if (self.directory) "Open a folder, then select Open or Save." else if (self.multiple) "Select files, then Open." else "Select a file." }, 0);
        defer self.allocator.free(status);
        self.message(status);
    }
    fn action(ptr: ?*anyopaque, id: usize) void {
        const self = cast(Dialog, ptr);
        if (self.finished) return;
        if (id == self.cancel_item) return self.finish(1, null);
        if (id == self.accept_item) return self.accept();
        self.overwrite = null;
        if (id == self.go_item or id == self.up_item) {
            const path = if (id == self.go_item) self.ui.get(self.path_item).value() else std.fs.path.dirname(self.folder) orelse "/";
            const owned = self.allocator.dupeSentinel(u8, path, 0) catch return;
            defer self.allocator.free(owned);
            self.navigate(owned) catch {
                self.message("Enter an absolute folder path.");
            };
        } else if (id == self.previous_item or id == self.next_item) {
            if (id == self.previous_item and self.page > 0) self.page -= 1 else if (id == self.next_item) self.page += 1;
            self.renderRows() catch {};
        } else {
            for (self.rows.items) |row| if (row.item == id) {
                const entry = self.listing.?.entries.items[row.entry];
                const path = std.fs.path.join(self.allocator, &.{ self.folder, entry.name }) catch return;
                defer self.allocator.free(path);
                const owned = self.allocator.dupeSentinel(u8, path, 0) catch return;
                defer self.allocator.free(owned);
                self.navigate(owned) catch {
                    self.message("Unable to open folder.");
                };
                break;
            };
        }
    }
    fn changed(ptr: ?*anyopaque, id: usize) void {
        const self = cast(Dialog, ptr);
        if (self.finished) return;
        self.overwrite = null;
        if (id == self.path_item) {
            self.initial_file = null;
            self.accept_after_scan = false;
        }
        if (id == self.hidden_item or self.filter_item == id) {
            self.page = 0;
            if (self.listing) |listing| for (listing.entries.items) |*entry| {
                entry.selected = false;
            };
            self.renderRows() catch {};
        } else for (self.rows.items) |row| if (row.item == id) {
            const selected = self.ui.get(id).checked;
            if (!self.multiple) {
                for (self.listing.?.entries.items) |*entry| entry.selected = false;
                for (self.rows.items) |other| if (other.item != id) self.ui.setChecked(other.item, false);
            }
            const entry = &self.listing.?.entries.items[row.entry];
            entry.selected = selected;
            if (self.name_item) |name| if (selected) self.ui.setText(name, entry.label) catch {};
            break;
        };
    }
    pub fn selectPath(self: *Dialog, path: [:0]const u8) !void {
        if (self.pending != null) return error.DirectoryLoading;
        const listing = self.listing orelse return error.DirectoryUnavailable;
        if (!eq(std.fs.path.dirname(path) orelse "/", self.folder)) return error.InvalidFileName;
        for (listing.entries.items) |*entry| if (eq(entry.name, std.fs.path.basename(path)) and self.visible(entry.*)) {
            if (entry.directory and !(self.directory and self.multiple)) return self.navigate(path);
            if (!self.multiple) for (listing.entries.items) |*other| {
                other.selected = false;
            };
            entry.selected = true;
            if (self.name_item) |id| try self.ui.setText(id, entry.label);
            try self.renderRows();
            return;
        };
        return error.NoSelection;
    }
    fn selectedPaths(self: *Dialog) !std.ArrayList([:0]const u8) {
        var selected: std.ArrayList([:0]const u8) = .empty;
        errdefer {
            for (selected.items) |path| self.allocator.free(path);
            selected.deinit(self.allocator);
        }
        if (self.name_item) |id| {
            const name = self.ui.get(id).value();
            if (name.len == 0 or eq(name, ".") or eq(name, "..") or std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidFileName;
            try selected.ensureUnusedCapacity(self.allocator, 1);
            selected.appendAssumeCapacity(try std.fmt.allocPrintSentinel(self.allocator, "{s}{s}{s}", .{ self.folder, if (std.mem.endsWith(u8, self.folder, "/")) "" else "/", name }, 0));
        } else if (self.listing) |listing| {
            for (listing.entries.items) |entry| if (entry.selected and self.visible(entry)) {
                const path = try std.fmt.allocPrintSentinel(self.allocator, "{s}{s}{s}", .{ self.folder, if (std.mem.endsWith(u8, self.folder, "/")) "" else "/", entry.name }, 0);
                errdefer self.allocator.free(path);
                try selected.append(self.allocator, path);
            };
        }
        if (self.directory and selected.items.len == 0) {
            const path = try self.allocator.dupeSentinel(u8, self.folder, 0);
            errdefer self.allocator.free(path);
            try selected.append(self.allocator, path);
        }
        return selected;
    }
    pub fn accept(self: *Dialog) void {
        if (self.finished or self.pending != null or self.listing == null) return;
        if (self.method == .save) {
            const paths = self.selectedPaths() catch {
                self.message("Enter a file name without slashes.");
                return;
            };
            defer {
                for (paths.items) |path| self.allocator.free(path);
                var owned = paths;
                owned.deinit(self.allocator);
            }
            const path = paths.items[0];
            const file = c.g_file_new_for_path(path);
            defer c.g_object_unref(file);
            if (c.g_file_query_file_type(file, 0, null) == 2) {
                self.navigate(path) catch {};
                return;
            }
            if (c.g_file_query_exists(file, null) != 0 and (self.overwrite == null or !eq(self.overwrite.?, path))) {
                self.overwrite = self.arena.allocator().dupeSentinel(u8, path, 0) catch return;
                self.message("This file exists. Select Save again to replace it, or edit the name.");
                return;
            }
        }
        const result = self.results() catch |err| {
            self.message(if (err == error.NoSelection) "Select a file before opening." else "Unable to select these files.");
            return;
        };
        self.finish(0, result);
    }
    pub fn cancel(self: *Dialog) void {
        self.finish(1, null);
    }
    fn key(ptr: ?*anyopaque, symbol: u32, modifiers: u32) bool {
        const self = cast(Dialog, ptr);
        if (self.finished) return false;
        if ((symbol == 'l' or symbol == 'L') and modifiers & c.GDK_CONTROL_MASK != 0) {
            self.ui.focusItem(self.path_item);
            self.ui.get(self.path_item).entry.?.buffer.selectAll();
            self.ui.redraw();
            return true;
        }
        if ((symbol == 's' or symbol == 'S' or symbol == 'o' or symbol == 'O') and modifiers & c.GDK_MOD1_MASK != 0) {
            self.accept();
            return true;
        }
        if (symbol != 0xff0d and symbol != 0xff8d) return false;
        if (self.ui.focus != self.path_item) {
            self.accept();
            return true;
        }
        const path = self.ui.get(self.path_item).value();
        if (!std.fs.path.isAbsolute(path)) {
            self.message("Enter an absolute folder or file path.");
            return true;
        }
        const file = c.g_file_new_for_path(path);
        defer c.g_object_unref(file);
        if (c.g_file_query_file_type(file, 0, null) == 2) {
            self.navigate(path) catch {};
        } else if (!self.directory) {
            const name = self.arena.allocator().dupeSentinel(u8, std.fs.path.basename(path), 0) catch return true;
            const folder = self.arena.allocator().dupeSentinel(u8, std.fs.path.dirname(path) orelse "/", 0) catch return true;
            if (self.name_item) |id| self.ui.setText(id, name) catch {};
            self.navigate(folder) catch {
                return true;
            };
            self.initial_file = name;
            self.accept_after_scan = true;
        }
        return true;
    }
    fn closed(_: *c.GtkWidget, ptr: ?*anyopaque) callconv(.c) void {
        cast(Dialog, ptr).cancel();
    }
    fn finish(self: *Dialog, code: u32, result: ?*c.GVariant) void {
        if (self.finished) return;
        self.finished = true;
        c.gtk_widget_hide(self.window);
        self.callback(self.data, code, result orelse c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "{sv}")), null, 0));
    }
    fn results(self: *Dialog) !?*c.GVariant {
        const out = builder("a{sv}");
        defer c.g_variant_builder_unref(out);
        const uris = builder("as");
        defer c.g_variant_builder_unref(uris);
        const selected = try self.selectedPaths();
        defer {
            for (selected.items) |path| self.allocator.free(path);
            var owned = selected;
            owned.deinit(self.allocator);
        }
        if (selected.items.len == 0) return error.NoSelection;
        if (self.method == .save_files) {
            const directory = c.g_file_new_for_path(selected.items[0]);
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
            for (selected.items) |path| {
                const file = c.g_file_new_for_path(path);
                defer c.g_object_unref(file);
                const uri = c.g_file_get_uri(file);
                defer c.g_free(uri);
                c.g_variant_builder_add(uris, "s", uri);
            }
        }
        c.g_variant_builder_add(out, "{sv}", @as([*:0]const u8, "uris"), c.g_variant_builder_end(uris));
        if (self.currentFilter()) |filter| c.g_variant_builder_add(out, "{sv}", @as([*:0]const u8, "current_filter"), filter.value);
        const choices = builder("a(ss)");
        defer c.g_variant_builder_unref(choices);
        for (self.choices.items) |choice| {
            const value: [*:0]const u8 = if (choice.boolean) (if (self.ui.get(choice.item).checked) "true" else "false") else self.ui.get(choice.item).selectedId().?.ptr;
            c.g_variant_builder_add(choices, "(ss)", choice.id.ptr, value);
        }
        c.g_variant_builder_add(out, "{sv}", @as([*:0]const u8, "choices"), c.g_variant_builder_end(choices));
        const writable = if (self.read_only) |id| !self.ui.get(id).checked else true;
        c.g_variant_builder_add(out, "{sv}", @as([*:0]const u8, "writable"), c.g_variant_new("b", @as(c_int, @intFromBool(writable))));
        return c.g_variant_builder_end(out);
    }
};
