//! Portal file chooser with native Zig form controls and asynchronous GIO enumeration.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const cast = c.__zig.cast;
const eq = c.__zig.eq;
const child = c.g_variant_get_child_value;
const text = c.__zig.variant.text;
const builder = c.__zig.variant.builder;
const Options = @import("desktop-portal-options.zig").Options(error.InvalidFileChooserOption);
const option = Options.get;
const boolean = Options.boolean;
const form = @import("desktop-form.zig");
const files = @import("desktop-file-list.zig");
const browser = @import("desktop-file-chooser-view.zig");
extern fn g_get_user_config_dir() [*:0]const u8;
pub const Completion = *const fn (?*anyopaque, u32, ?*c.GVariant) void;
pub const Choice = struct { id: [:0]const u8, item: usize, boolean: bool };
pub const Filter = struct { value: *c.GVariant, id: [:0]const u8, name: [:0]const u8, rules: []const files.Rule };
const Row = browser.Row;
pub const Dialog = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    window: *form.host.Window,
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
    visible_entries: std.ArrayList(usize) = .empty,
    places: std.ArrayList(browser.Place) = .empty,
    history: std.ArrayList([:0]const u8) = .empty,
    history_index: usize = 0,
    history_navigation: bool = false,
    selection_anchor: ?usize = null,
    view: browser.View = .{},
    read_only: ?usize = null,
    filter_item: ?usize = null,
    name_item: ?usize = null,
    path_item: usize = 0,
    up_item: usize = 0,
    go_item: usize = 0,
    hidden_item: usize = 0,
    message_item: usize = 0,
    cancel_item: usize = 0,
    accept_item: usize = 0,
    dynamic_start: usize = 0,
    folder: [:0]const u8 = "",
    listing: ?*files.Scan = null,
    pending: ?*files.Scan = null,
    pending_count: usize = 0,
    initial_file: ?[:0]const u8 = null,
    accept_after_scan: bool = false,
    overwrite: ?[:0]const u8 = null,
    finished: bool = false,
    finish_idle: c.guint = 0,
    finish_code: u32 = 1,
    finish_result: ?*c.GVariant = null,
    dead: bool = false,
    // Only visible rows and a small look-ahead window own form controls.
    const window_items = 512;

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
        _ = try boolean(options, "modal", true);
        ui.window.surface.?.options.parent = try self.arena.allocator().dupeSentinel(u8, parent, 0);
        self.path_item = try ui.add(.entry, "Location", "", false);
        self.up_item = try ui.add(.button, "Parent folder", "", false);
        self.go_item = try ui.add(.button, "Go", "", false);
        self.hidden_item = try ui.add(.toggle, "Show hidden files", "", false);
        if (kind == .save) {
            self.name_item = try ui.add(.entry, "File name", "", false);
            const name = try option(options, "current_name", "s");
            defer if (name != null) c.g_variant_unref(name);
            if (name != null) try ui.setText(self.name_item.?, text(name));
        }
        try self.configureFilters();
        try self.configureChoices(kind == .open and !self.directory);
        self.message_item = try ui.addPinned(.label, "Loading folder…");
        self.cancel_item = try ui.addPinned(.button, "Cancel");
        const accept_label = try option(options, "accept_label", "s");
        defer if (accept_label != null) c.g_variant_unref(accept_label);
        self.accept_item = try ui.addPinned(.button, if (accept_label != null) text(accept_label) else if (kind == .open) "Open" else "Save");
        self.view = .{
            .path = self.path_item,
            .up = self.up_item,
            .location = self.go_item,
            .hidden = self.hidden_item,
            .name = self.name_item,
            .filter = self.filter_item,
            .message = self.message_item,
            .cancel = self.cancel_item,
            .accept = self.accept_item,
            .back = try ui.add(.button, "Back", "", false),
            .forward = try ui.add(.button, "Forward", "", false),
            .search = try ui.add(.button, "Search", "", false),
            .query = try ui.add(.entry, "Search in this folder", "", false),
            .folder_search = try ui.add(.button, "Search in this folder", "", false),
            .toggle_view = try ui.add(.button, "View", "", false),
            .menu = try ui.add(.button, "View options", "", false),
            .options = try ui.add(.button, "File options", "", false),
        };
        var extras: std.ArrayList(usize) = .empty;
        for (self.choices.items) |choice| try extras.append(self.arena.allocator(), choice.item);
        if (self.read_only) |id| try extras.append(self.arena.allocator(), id);
        self.view.extras = extras.items;
        try self.addPlace("Home", std.mem.span(c.g_get_home_dir()), "user-home-symbolic");
        const labels = [_][:0]const u8{ "Desktop", "Documents", "Downloads", "Music", "Pictures", "Public", "Templates", "Videos" };
        const icons = [_][:0]const u8{ "user-desktop-symbolic", "folder-documents-symbolic", "folder-download-symbolic", "folder-music-symbolic", "folder-pictures-symbolic", "folder-publicshare-symbolic", "folder-templates-symbolic", "folder-videos-symbolic" };
        for (labels, icons, 0..) |label, icon, i| {
            if (i == 0 or i == 5 or i == 6) continue;
            const path = c.g_get_user_special_dir(@intCast(i));
            if (path == null) continue;
            const file = c.g_file_new_for_path(path);
            defer c.g_object_unref(file);
            if (c.g_file_query_file_type(file, 0, null) == 2) try self.addPlace(label, std.mem.span(path), icon);
        }
        try self.addBookmarks();
        try self.addPlace("File System", "/", "drive-harddisk-symbolic");
        self.view.places = self.places.items;
        self.dynamic_start = ui.items.items.len;
        self.window.setSize(900, 600);
        ui.window.surface.?.options.min_width = 580;
        ui.window.surface.?.options.min_height = 348;
        ui.layout = &layout;
        ui.painter = &paint;
        ui.scrolled = &scrolled;
        ui.double_clicked = &activated;
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
        ui.close_callback = &closed;
        ui.shortcut = &key;
        ui.show();
        ui.focus = null;
        return self;
    }
    fn freeResources(self: *Dialog) void {
        self.view.deinit();
        self.visible_entries.deinit(self.allocator);
        if (self.listing) |listing| listing.destroy();
        for (self.filters.items) |filter| c.g_variant_unref(filter.value);
        c.g_variant_unref(self.options);
        self.arena.deinit();
    }
    fn addPlace(self: *Dialog, label: [:0]const u8, path: [:0]const u8, icon: [:0]const u8) !void {
        for (self.places.items) |place| if (eq(place.path, path)) return;
        try self.places.append(self.arena.allocator(), .{ .item = try self.ui.add(.button, label, "", false), .path = try self.arena.allocator().dupeSentinel(u8, path, 0), .icon = icon });
    }
    fn addBookmarks(self: *Dialog) !void {
        const a = self.arena.allocator();
        const filename = try std.fmt.allocPrintSentinel(a, "{s}/gtk-3.0/bookmarks", .{g_get_user_config_dir()}, 0);
        var contents: [*c]u8 = null;
        var size: usize = 0;
        if (c.g_file_get_contents(filename, &contents, &size, null) == 0) return;
        defer c.g_free(contents);
        var lines = std.mem.splitScalar(u8, contents[0..size], '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r");
            const split = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
            if (!std.mem.startsWith(u8, trimmed, "file://")) continue;
            const uri = try a.dupeSentinel(u8, trimmed[0..split], 0);
            const path = c.g_filename_from_uri(uri, null, null) orelse continue;
            defer c.g_free(path);
            const file = c.g_file_new_for_path(path);
            defer c.g_object_unref(file);
            if (c.g_file_query_file_type(file, 0, null) != 2) continue;
            const label = if (split < trimmed.len) trimmed[split + 1 ..] else std.fs.path.basename(std.mem.span(path));
            if (!std.unicode.utf8ValidateSlice(label)) continue;
            try self.addPlace(try a.dupeSentinel(u8, label, 0), std.mem.span(path), "folder-symbolic");
        }
    }
    fn layout(ui: *form.Form) void {
        cast(Dialog, ui.context).view.layout(ui);
    }
    fn paint(ui: *form.Form, target: @import("desktop-raster.zig").Buffer, scale: u32) !void {
        try cast(Dialog, ui.context).view.paint(ui, target, scale);
    }
    pub fn scrollBy(self: *Dialog, delta: f64) void {
        self.view.offset = std.math.clamp(self.view.offset + delta, 0, self.view.maxOffset());
        self.renderRows() catch self.message("Unable to display files.");
    }
    fn scrolled(ptr: ?*anyopaque, delta: f64) void {
        cast(Dialog, ptr).scrollBy(delta);
    }
    fn activated(ptr: ?*anyopaque, id: usize) void {
        const self = cast(Dialog, ptr);
        for (self.rows.items) |row| if (row.item == id) {
            self.openEntry(row.entry);
            return;
        };
    }
    fn openEntry(self: *Dialog, index: usize) void {
        const entry = &self.listing.?.entries.items[index];
        if (!entry.directory) {
            entry.selected = true;
            self.accept();
            return;
        }
        const path = std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ self.folder, entry.name }, 0) catch return;
        defer self.allocator.free(path);
        self.navigate(path) catch self.message("Unable to open folder.");
    }
    pub fn destroy(self: *Dialog) void {
        if (self.dead) return;
        self.dead = true;
        if (self.finish_idle != 0) _ = c.g_source_remove(self.finish_idle);
        if (self.finish_result) |value| c.g_variant_unref(value);
        if (self.pending) |pending| pending.cancel();
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
        try self.ui.setText(self.view.query, "");
        if (!self.history_navigation) try self.history.ensureUnusedCapacity(self.arena.allocator(), 1);
        const scan = try files.Scan.start(self.allocator, copy, self, &scanned);
        if (self.pending) |previous| previous.cancel();
        self.pending = scan;
        self.pending_count += 1;
        self.folder = copy;
        self.view.folder = copy;
        self.view.offset = 0;
        self.view.loading = true;
        self.view.count = 0;
        self.view.selected_count = 0;
        self.view.selected_name = "";
        self.view.rows = &.{};
        self.view.editing_location = false;
        self.ui.focus = null;
        self.view.searching = false;
        self.view.menu_open = false;
        self.view.options_open = false;
        self.selection_anchor = null;
        if (!self.history_navigation) {
            if (self.history.items.len != 0) self.history.shrinkRetainingCapacity(self.history_index + 1);
            self.history.appendAssumeCapacity(copy);
            self.history_index = self.history.items.len - 1;
        }
        self.ui.get(self.view.back).enabled = self.history_index > 0;
        self.ui.get(self.view.forward).enabled = self.history_index + 1 < self.history.items.len;
        self.overwrite = null;
        self.initial_file = null;
        self.accept_after_scan = false;
        self.rows.clearRetainingCapacity();
        self.visible_entries.clearRetainingCapacity();
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
            self.view.loading = false;
            scan.destroy();
            self.message(if (err == error.DirectoryTooLarge) "Folder has too many files. Enter a more specific folder." else "Unable to read this folder. Check its path and permissions.");
            return;
        }
        self.listing = scan;
        self.view.loading = false;
        if (self.initial_file) |name| {
            for (scan.entries.items) |*entry| if (eq(entry.name, name)) {
                entry.selected = true;
                break;
            };
            self.initial_file = null;
        }
        self.rebuildRows() catch {
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
        const query = self.ui.get(self.view.query).value();
        if (query.len > 0) {
            const needle = c.g_utf8_casefold(query, -1);
            defer c.g_free(needle);
            const name = c.g_utf8_casefold(entry.label, -1);
            defer c.g_free(name);
            if (std.mem.indexOf(u8, std.mem.span(name), std.mem.span(needle)) == null) return false;
        }
        return files.matches(entry, if (self.currentFilter()) |filter| filter.rules else &.{});
    }
    fn rebuildRows(self: *Dialog) !void {
        self.visible_entries.clearRetainingCapacity();
        if (self.listing) |listing| for (listing.entries.items, 0..) |entry, i| {
            if (self.visible(entry)) try self.visible_entries.append(self.allocator, i);
        };
        self.view.count = self.visible_entries.items.len;
        try self.renderRows();
    }
    fn fileIcon(entry: files.Entry) [:0]const u8 {
        if (entry.directory) return "folder";
        const extension = std.fs.path.extension(entry.name);
        if (std.ascii.eqlIgnoreCase(extension, ".pdf") or std.ascii.eqlIgnoreCase(extension, ".md")) return "x-office-document";
        const mime = entry.content_type orelse return "text-x-generic";
        if (std.mem.startsWith(u8, mime, "image/")) return "image-x-generic";
        if (std.mem.startsWith(u8, mime, "video/")) return "video-x-generic";
        if (std.mem.startsWith(u8, mime, "audio/")) return "audio-x-generic";
        if (eq(mime, "application/pdf")) return "application-pdf";
        if (std.mem.indexOf(u8, mime, "zip") != null or std.mem.indexOf(u8, mime, "compressed") != null) return "package-x-generic";
        return "text-x-generic";
    }
    fn renderRows(self: *Dialog) !void {
        self.view.rows = &.{};
        self.rows.clearRetainingCapacity();
        self.ui.updating = true;
        defer {
            self.ui.updating = false;
            self.view.rows = self.rows.items;
            self.ui.relayout();
        }
        self.ui.truncate(self.dynamic_start);
        const listing = self.listing orelse return;
        const first = @min(self.view.first(), self.visible_entries.items.len);
        const last = @min(first + window_items, self.visible_entries.items.len);
        for (self.visible_entries.items[first..last], first..) |index, ordinal| {
            const entry = listing.entries.items[index];
            const id = try self.ui.add(.toggle, entry.label, "", false);
            self.ui.setChecked(id, entry.selected);
            try self.rows.append(self.arena.allocator(), .{ .item = id, .entry = index, .ordinal = ordinal, .icon = fileIcon(entry), .size = entry.size, .modified = entry.modified, .directory = entry.directory });
        }
        self.syncAccept();
        self.message("");
    }
    fn syncAccept(self: *Dialog) void {
        var selected = false;
        self.view.selected_count = 0;
        self.view.selected_size = 0;
        self.view.selected_name = "";
        if (self.listing) |listing| for (listing.entries.items) |entry| {
            if (entry.selected and self.visible(entry)) {
                selected = true;
                self.view.selected_count += 1;
                self.view.selected_size +|= if (entry.directory) 0 else entry.size;
                self.view.selected_name = entry.label;
                self.view.selected_directory = entry.directory;
            }
        };
        self.ui.get(self.accept_item).enabled = self.directory or (if (self.name_item) |id| self.ui.get(id).value().len > 0 else selected);
    }
    fn action(ptr: ?*anyopaque, id: usize) void {
        const self = cast(Dialog, ptr);
        if (self.finished) return;
        if (id == self.cancel_item) return self.finish(1, null);
        if (id == self.accept_item) return self.accept();
        self.overwrite = null;
        if (id == self.go_item) {
            self.view.editing_location = true;
            self.view.searching = false;
            self.ui.relayout();
            self.ui.focusItem(self.path_item);
            self.ui.get(self.path_item).entry.?.buffer.selectAll();
        } else if (id == self.up_item) {
            const path = std.fs.path.dirname(self.folder) orelse "/";
            const owned = self.allocator.dupeSentinel(u8, path, 0) catch return;
            defer self.allocator.free(owned);
            self.navigate(owned) catch {
                self.message("Enter an absolute folder path.");
            };
        } else if (id == self.view.back or id == self.view.forward) {
            if (id == self.view.back and self.history_index > 0) self.history_index -= 1 else if (id == self.view.forward and self.history_index + 1 < self.history.items.len) self.history_index += 1 else return;
            self.history_navigation = true;
            defer self.history_navigation = false;
            self.navigate(self.history.items[self.history_index]) catch {};
        } else if (id == self.view.toggle_view) {
            self.view.grid = !self.view.grid;
            self.view.offset = 0;
            self.ui.relayout();
            self.renderRows() catch {};
        } else if (id == self.view.search or id == self.view.folder_search) {
            self.view.searching = !self.view.searching;
            self.view.editing_location = false;
            if (!self.view.searching) self.ui.setText(self.view.query, "") catch {};
            self.ui.relayout();
            if (self.view.searching) self.ui.focusItem(self.view.query);
            self.rebuildRows() catch {};
        } else if (id == self.view.menu or id == self.view.options) {
            if (id == self.view.menu) self.view.menu_open = !self.view.menu_open else self.view.options_open = !self.view.options_open;
            self.ui.relayout();
        } else {
            for (self.places.items) |place| if (place.item == id) {
                self.navigate(place.path) catch self.message("Unable to open folder.");
                return;
            };
            for (self.rows.items) |row| if (row.item == id) {
                self.openEntry(row.entry);
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
        if (id == self.hidden_item or self.filter_item == id or id == self.view.query) {
            self.view.offset = 0;
            self.selection_anchor = null;
            if (self.listing) |listing| for (listing.entries.items) |*entry| {
                entry.selected = false;
            };
            self.rebuildRows() catch {};
        } else for (self.rows.items) |row| if (row.item == id) {
            self.view.menu_open = false;
            self.view.options_open = false;
            const selected = self.ui.get(id).checked;
            const control = self.ui.input_modifiers & c.GDK_CONTROL_MASK != 0;
            const shift = self.ui.input_modifiers & c.GDK_SHIFT_MASK != 0;
            if (!self.multiple or (!control and !shift)) {
                for (self.listing.?.entries.items) |*entry| entry.selected = false;
                for (self.rows.items) |other| if (other.item != id) self.ui.setChecked(other.item, false);
            }
            const entry = &self.listing.?.entries.items[row.entry];
            entry.selected = if (self.multiple) selected else true;
            if (self.multiple and shift and self.selection_anchor != null) {
                const first = @min(row.ordinal, self.selection_anchor.?);
                const last = @max(row.ordinal, self.selection_anchor.?);
                for (self.visible_entries.items, 0..) |index, ordinal| self.listing.?.entries.items[index].selected = ordinal >= first and ordinal <= last;
                for (self.rows.items) |other| self.ui.setChecked(other.item, self.listing.?.entries.items[other.entry].selected);
            } else self.selection_anchor = row.ordinal;
            self.ui.setChecked(id, entry.selected);
            if (self.name_item) |name| if (selected) self.ui.setText(name, entry.label) catch {};
            self.ui.relayout();
            break;
        };
        self.syncAccept();
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
            for (self.visible_entries.items, 0..) |index, ordinal| if (&listing.entries.items[index] == entry) {
                self.view.reveal(ordinal);
                break;
            };
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
            for (listing.entries.items) |entry| if (entry.selected and self.visible(entry) and (self.directory or !entry.directory)) {
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
        if (self.finished) return;
        if (self.pending != null) {
            self.accept_after_scan = true;
            return;
        }
        if (self.listing == null) return;
        if (self.method == .open and !self.directory) {
            var folder: ?usize = null;
            var files_selected = false;
            for (self.listing.?.entries.items, 0..) |entry, index| if (entry.selected and self.visible(entry)) {
                if (entry.directory) folder = index else files_selected = true;
            };
            if (!files_selected) if (folder) |index| return self.openEntry(index);
        }
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
        self.ui.input_modifiers = modifiers;
        if (symbol == 0xff1b and (self.view.menu_open or self.view.options_open or self.view.editing_location or self.view.searching)) {
            self.view.menu_open = false;
            self.view.options_open = false;
            self.view.editing_location = false;
            self.view.searching = false;
            self.ui.expanded = null;
            self.ui.setText(self.view.query, "") catch {};
            self.rebuildRows() catch {};
            self.ui.focus = null;
            return true;
        }
        if ((symbol == 'l' or symbol == 'L') and modifiers & c.GDK_CONTROL_MASK != 0) {
            self.view.editing_location = true;
            self.view.searching = false;
            self.ui.relayout();
            self.ui.focusItem(self.path_item);
            self.ui.get(self.path_item).entry.?.buffer.selectAll();
            self.ui.redraw();
            return true;
        }
        if ((symbol == 'f' or symbol == 'F') and modifiers & c.GDK_CONTROL_MASK != 0) {
            if (!self.view.searching) action(self, self.view.search);
            return true;
        }
        if ((symbol == '1' or symbol == '2') and modifiers & c.GDK_CONTROL_MASK != 0) {
            if (self.view.grid != (symbol == '2')) action(self, self.view.toggle_view);
            return true;
        }
        if ((symbol == 'h' or symbol == 'H') and modifiers & c.GDK_CONTROL_MASK != 0) {
            self.ui.setChecked(self.hidden_item, !self.ui.get(self.hidden_item).checked);
            changed(self, self.hidden_item);
            return true;
        }
        if (modifiers & c.GDK_MOD1_MASK != 0) switch (symbol) {
            0xff51 => {
                action(self, self.view.back);
                return true;
            },
            0xff53 => {
                action(self, self.view.forward);
                return true;
            },
            0xff52 => {
                action(self, self.up_item);
                return true;
            },
            else => {},
        };
        if ((symbol == 's' or symbol == 'S' or symbol == 'o' or symbol == 'O') and modifiers & c.GDK_MOD1_MASK != 0) {
            self.accept();
            return true;
        }
        if (!self.view.editing_location and (!self.view.searching or self.ui.focus != self.view.query or symbol == 0xff54) and (self.name_item == null or self.ui.focus != self.name_item) and self.ui.expanded == null) {
            var ordinal: usize = 0;
            var focused = false;
            if (self.ui.focus) |id| for (self.rows.items) |row| if (row.item == id) {
                ordinal = row.ordinal;
                focused = true;
                break;
            };
            const count = self.visible_entries.items.len;
            if (count > 0 and (symbol == 0xff51 or symbol == 0xff52 or symbol == 0xff53 or symbol == 0xff54 or symbol == 0xff50 or symbol == 0xff57)) {
                const step = if (symbol == 0xff52 or symbol == 0xff54) self.view.columns else 1;
                ordinal = if (!focused and symbol != 0xff57) 0 else switch (symbol) {
                    0xff51, 0xff52 => ordinal -| step,
                    0xff50 => 0,
                    0xff57 => count - 1,
                    else => @min(count - 1, ordinal + step),
                };
                self.view.reveal(ordinal);
                self.renderRows() catch return true;
                for (self.rows.items) |row| if (row.ordinal == ordinal) {
                    self.ui.focusItem(row.item);
                    self.ui.setChecked(row.item, true);
                    changed(self, row.item);
                    break;
                };
                return true;
            }
            if (self.multiple and (symbol == 'a' or symbol == 'A') and modifiers & c.GDK_CONTROL_MASK != 0 and self.ui.focus != self.view.query) {
                if (self.listing) |listing| for (self.visible_entries.items) |index| {
                    listing.entries.items[index].selected = self.directory or !listing.entries.items[index].directory;
                };
                self.renderRows() catch {};
                return true;
            }
        }
        if (symbol != 0xff0d and symbol != 0xff8d) return false;
        if (self.ui.focus) |id| for (self.rows.items) |row| if (row.item == id) {
            self.openEntry(row.entry);
            return true;
        };
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
    fn closed(ptr: ?*anyopaque) void {
        cast(Dialog, ptr).cancel();
    }
    fn finish(self: *Dialog, code: u32, result: ?*c.GVariant) void {
        if (self.finished) return;
        self.finished = true;
        self.window.hide();
        if (self.ui.dispatching) {
            self.finish_code = code;
            // Own the floating reply until it is transferred to the callback.
            self.finish_result = result orelse c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "{sv}")), null, 0);
            self.finish_idle = c.g_idle_add(&deliverFinish, self);
        } else self.callback(self.data, code, result orelse c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "{sv}")), null, 0));
    }
    fn deliverFinish(ptr: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Dialog, ptr);
        self.finish_idle = 0;
        const result = self.finish_result;
        self.finish_result = null;
        self.callback(self.data, self.finish_code, result);
        return 0;
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
