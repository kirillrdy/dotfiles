//! Native print dialogs and submission, with single-use, caller-owned settings.
const std = @import("std");
const c = @import("gtk");
const libc = @import("libc");
const cast = c.__zig.cast;
const eq = c.__zig.eq;
fn option(options: ?*c.GVariant, key: [*:0]const u8, signature: [:0]const u8) !?*c.GVariant {
    const value = c.g_variant_lookup_value(options, key, null) orelse return null;
    if (!eq(std.mem.span(c.g_variant_get_type_string(value)), signature)) {
        c.g_variant_unref(value);
        return error.InvalidPrintOption;
    }
    return value;
}
fn boolean(options: ?*c.GVariant, key: [*:0]const u8, fallback: bool) !bool {
    const value = try option(options, key, "b") orelse return fallback;
    defer c.g_variant_unref(value);
    return c.g_variant_get_boolean(value) != 0;
}
fn empty() ?*c.GVariant {
    return c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "{sv}")), null, 0);
}
fn capabilities(options: ?*c.GVariant) !c.GtkPrintCapabilities {
    var result: c.GtkPrintCapabilities = c.GTK_PRINT_CAPABILITY_PAGE_SET | c.GTK_PRINT_CAPABILITY_COPIES | c.GTK_PRINT_CAPABILITY_COLLATE | c.GTK_PRINT_CAPABILITY_REVERSE | c.GTK_PRINT_CAPABILITY_SCALE | c.GTK_PRINT_CAPABILITY_NUMBER_UP | c.GTK_PRINT_CAPABILITY_NUMBER_UP_LAYOUT;
    const formats = try option(options, "supported_output_file_formats", "as") orelse return result;
    defer c.g_variant_unref(formats);
    if (c.g_variant_n_children(formats) == 0) return error.InvalidOutputFormats;
    var svg = false;
    for (0..c.g_variant_n_children(formats)) |index| {
        const value = c.g_variant_get_child_value(formats, index);
        defer c.g_variant_unref(value);
        const format = std.mem.span(c.g_variant_get_string(value, null));
        if (eq(format, "pdf")) result |= c.GTK_PRINT_CAPABILITY_GENERATE_PDF else if (eq(format, "ps")) result |= c.GTK_PRINT_CAPABILITY_GENERATE_PS else if (eq(format, "svg")) svg = true else return error.InvalidOutputFormats;
    }
    // GTK represents support for all three formats by omitting both flags.
    if (svg) result &= ~@as(c.GtkPrintCapabilities, c.GTK_PRINT_CAPABILITY_GENERATE_PDF | c.GTK_PRINT_CAPABILITY_GENERATE_PS);
    return result;
}
fn validateSettings(settings: ?*c.GVariant, page: bool) !void {
    if (settings == null) return;
    for (0..c.g_variant_n_children(settings)) |index| {
        const entry = c.g_variant_get_child_value(settings, index);
        defer c.g_variant_unref(entry);
        const key = c.g_variant_get_child_value(entry, 0);
        defer c.g_variant_unref(key);
        const wrapped = c.g_variant_get_child_value(entry, 1);
        defer c.g_variant_unref(wrapped);
        const value = c.g_variant_get_variant(wrapped);
        defer c.g_variant_unref(value);
        const name = std.mem.span(c.g_variant_get_string(key, null));
        const number = page and (eq(name, "Width") or eq(name, "Height") or std.mem.startsWith(u8, name, "Margin"));
        if (!eq(std.mem.span(c.g_variant_get_type_string(value)), if (number) "d" else "s")) return error.InvalidPrintSettings;
        if (number) {
            const size = c.g_variant_get_double(value);
            if (!std.math.isFinite(size) or size < 0 or ((eq(name, "Width") or eq(name, "Height")) and size == 0)) return error.InvalidPrintSettings;
        }
    }
}

const Prepared = struct {
    allocator: std.mem.Allocator,
    owner: [:0]const u8,
    printer: *c.GtkPrinter,
    settings: *c.GtkPrintSettings,
    page: *c.GtkPageSetup,
    token: u32 = 0,
    expires: i64 = 0,
    fn destroy(self: *Prepared) void {
        c.g_object_unref(self.printer);
        c.g_object_unref(self.settings);
        c.g_object_unref(self.page);
        self.allocator.free(self.owner);
        self.allocator.destroy(self);
    }
};
pub const Service = struct {
    allocator: std.mem.Allocator,
    prepared: std.ArrayList(*Prepared) = .empty,
    timer: c.guint = 0,
    pub fn create(allocator: std.mem.Allocator) !*Service {
        const self = try allocator.create(Service);
        self.* = .{ .allocator = allocator };
        self.timer = c.g_timeout_add_seconds(30, &expire, self);
        return self;
    }
    pub fn destroy(self: *Service) void {
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        for (self.prepared.items) |item| item.destroy();
        self.prepared.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    pub fn removeOwner(self: *Service, owner: []const u8) void {
        var i: usize = 0;
        while (i < self.prepared.items.len) {
            if (eq(self.prepared.items[i].owner, owner)) self.prepared.swapRemove(i).destroy() else i += 1;
        }
    }
    fn expire(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Service, data);
        var i: usize = 0;
        while (i < self.prepared.items.len) {
            if (self.prepared.items[i].expires <= c.g_get_monotonic_time()) self.prepared.swapRemove(i).destroy() else i += 1;
        }
        return 1;
    }
    fn remember(self: *Service, params: *Prepared) !void {
        _ = expire(self);
        if (self.prepared.items.len >= 64) return error.TooManyPreparedPrints;
        while (true) {
            params.token = c.g_random_int();
            if (params.token == 0) continue;
            var duplicate = false;
            for (self.prepared.items) |item| if (item.token == params.token) {
                duplicate = true;
                break;
            };
            if (!duplicate) break;
        }
        params.expires = c.g_get_monotonic_time() + 300_000_000;
        try self.prepared.append(self.allocator, params);
    }
    fn take(self: *Service, owner: []const u8, token: u32) !*Prepared {
        _ = expire(self);
        for (self.prepared.items, 0..) |item, index| {
            if (item.token == token and eq(item.owner, owner)) return self.prepared.swapRemove(index);
        }
        return error.InvalidPrintToken;
    }
};

pub const Completion = *const fn (?*anyopaque, u32, ?*c.GVariant) void;
pub const Operation = struct {
    service: *Service,
    arena: std.heap.ArenaAllocator,
    owner: [:0]const u8,
    title: [:0]const u8,
    window: ?*c.GtkWidget = null,
    job: ?*c.GtkPrintJob = null,
    params: ?*Prepared = null,
    source_fd: c_int = -1,
    idle: c.guint = 0,
    preparing: bool,
    finished: bool = false,
    callback: Completion,
    data: ?*anyopaque,

    pub fn create(service: *Service, owner: [:0]const u8, parent: [:0]const u8, title: [:0]const u8, settings: ?*c.GVariant, page: ?*c.GVariant, options: *c.GVariant, descriptors: ?*c.GUnixFDList, fd_index: ?c_int, callback: Completion, data: ?*anyopaque) !*Operation {
        try validateSettings(settings, false);
        try validateSettings(page, true);
        const caps = try capabilities(options);
        const modal = try boolean(options, "modal", true);
        const current = try boolean(options, "has_current_page", false);
        const selected = try boolean(options, "has_selected_pages", false);
        const accept = try option(options, "accept_label", "s");
        defer if (accept != null) c.g_variant_unref(accept);
        const token = try option(options, "token", "u");
        defer if (token != null) c.g_variant_unref(token);
        if (c.gtk_init_check(null, null) == 0) return error.DisplayUnavailable;
        const a = service.allocator;
        const self = try a.create(Operation);
        self.* = .{ .service = service, .arena = std.heap.ArenaAllocator.init(a), .owner = undefined, .title = undefined, .preparing = fd_index == null, .callback = callback, .data = data };
        errdefer self.destroy();
        self.owner = try self.arena.allocator().dupeSentinel(u8, owner, 0);
        self.title = try self.arena.allocator().dupeSentinel(u8, title, 0);
        if (fd_index) |index| {
            const list = descriptors orelse return error.MissingFileDescriptor;
            if (index < 0 or index >= c.g_unix_fd_list_get_length(list)) return error.InvalidFileDescriptor;
            self.source_fd = c.g_unix_fd_list_get(list, index, null);
            if (self.source_fd < 0) return error.InvalidFileDescriptor;
            var stat: std.os.linux.Statx = undefined;
            const flags = std.c.fcntl(self.source_fd, std.c.F.GETFL);
            if (flags < 0 or @as(std.c.O, @bitCast(@as(u32, @intCast(flags)))).ACCMODE == .WRONLY or std.c.statx(self.source_fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stat) != 0 or !stat.mask.TYPE or stat.mode & std.c.S.IFMT != std.c.S.IFREG) return error.InvalidPrintFile;
            if (std.c.lseek64(self.source_fd, 0, std.c.SEEK.SET) < 0) return error.InvalidPrintFile;
            if (token != null and c.g_variant_get_uint32(token) != 0) {
                self.params = try service.take(owner, c.g_variant_get_uint32(token));
                // Return the request handle before a backend can complete.
                self.idle = c.g_idle_add(&submitIdle, self);
                return self;
            }
        }
        self.window = c.gtk_print_unix_dialog_new(title, null).?;
        const dialog = cast(c.GtkPrintUnixDialog, self.window);
        c.gtk_window_set_modal(cast(c.GtkWindow, self.window), @intFromBool(modal));
        c.gtk_dialog_set_default_response(cast(c.GtkDialog, self.window), c.GTK_RESPONSE_CANCEL);
        c.gtk_print_unix_dialog_set_manual_capabilities(dialog, caps);
        c.gtk_print_unix_dialog_set_embed_page_setup(dialog, 1);
        c.gtk_print_unix_dialog_set_current_page(dialog, if (current) 0 else -1);
        c.gtk_print_unix_dialog_set_support_selection(dialog, @intFromBool(selected));
        c.gtk_print_unix_dialog_set_has_selection(dialog, @intFromBool(selected));
        if (settings != null) {
            const initial = c.gtk_print_settings_new_from_gvariant(settings);
            defer c.g_object_unref(initial);
            c.gtk_print_unix_dialog_set_settings(dialog, initial);
        }
        if (page != null) {
            const initial = c.gtk_page_setup_new_from_gvariant(page);
            defer c.g_object_unref(initial);
            c.gtk_print_unix_dialog_set_page_setup(dialog, initial);
        }
        if (accept != null) {
            const button = c.gtk_dialog_get_widget_for_response(cast(c.GtkDialog, self.window), c.GTK_RESPONSE_OK);
            c.gtk_button_set_label(cast(c.GtkButton, button), c.g_variant_get_string(accept, null));
        }
        _ = c.g_signal_connect_data(self.window, "response", @ptrCast(&responded), self, null, 0);
        c.gtk_widget_show(self.window);
        c.gtk_window_present(cast(c.GtkWindow, self.window));
        @import("desktop-portal-window.zig").parentTo(self.window.?, a, parent);
        return self;
    }
    // A submitted job owns an asynchronous callback; keep its request alive
    // until completion even when the caller has closed or disconnected.
    pub fn pending(self: *Operation) bool {
        return self.job != null;
    }
    pub fn destroy(self: *Operation) void {
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        if (self.window) |window| {
            _ = c.g_signal_handlers_disconnect_matched(window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            c.gtk_widget_destroy(window);
        }
        if (self.job != null) c.g_object_unref(self.job);
        if (self.source_fd >= 0) _ = libc.close(self.source_fd);
        if (self.params) |params| params.destroy();
        self.arena.deinit();
        self.service.allocator.destroy(self);
    }
    fn capture(self: *Operation) !*Prepared {
        const dialog = cast(c.GtkPrintUnixDialog, self.window);
        const printer = c.gtk_print_unix_dialog_get_selected_printer(dialog) orelse return error.NoPrinter;
        const owner = try self.service.allocator.dupeSentinel(u8, self.owner, 0);
        errdefer self.service.allocator.free(owner);
        const params = try self.service.allocator.create(Prepared);
        params.* = .{ .allocator = self.service.allocator, .owner = owner, .printer = cast(c.GtkPrinter, c.g_object_ref(printer)), .settings = c.gtk_print_unix_dialog_get_settings(dialog).?, .page = cast(c.GtkPageSetup, c.g_object_ref(c.gtk_print_unix_dialog_get_page_setup(dialog))) };
        return params;
    }
    fn responded(_: *c.GtkDialog, response: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Operation, data);
        if (self.finished) return;
        self.finished = true;
        c.gtk_widget_hide(self.window);
        if (response != c.GTK_RESPONSE_OK) {
            self.callback(self.data, 1, empty());
            return;
        }
        const params = self.capture() catch {
            self.callback(self.data, 2, empty());
            return;
        };
        if (!self.preparing) {
            self.params = params;
            self.submit();
            return;
        }
        self.service.remember(params) catch {
            params.destroy();
            self.callback(self.data, 2, empty());
            return;
        };
        const result = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
        defer c.g_variant_builder_unref(result);
        c.g_variant_builder_add(result, "{sv}", @as([*:0]const u8, "settings"), c.gtk_print_settings_to_gvariant(params.settings));
        c.g_variant_builder_add(result, "{sv}", @as([*:0]const u8, "page-setup"), c.gtk_page_setup_to_gvariant(params.page));
        c.g_variant_builder_add(result, "{sv}", @as([*:0]const u8, "token"), c.g_variant_new("u", params.token));
        self.callback(self.data, 0, c.g_variant_builder_end(result));
    }
    fn submitIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Operation, data);
        self.idle = 0;
        self.submit();
        return 0;
    }
    fn submit(self: *Operation) void {
        const params = self.params.?;
        self.job = c.gtk_print_job_new(self.title, params.printer, params.settings, params.page);
        if (c.gtk_print_job_set_source_fd(self.job, self.source_fd, null) == 0) {
            self.callback(self.data, 2, empty());
            return;
        }
        c.gtk_print_job_send(self.job, &sent, self, null);
    }
    fn sent(_: ?*c.GtkPrintJob, data: ?*anyopaque, err: [*c]const c.GError) callconv(.c) void {
        const self = cast(Operation, data);
        self.callback(self.data, if (err == null) 0 else 2, empty());
    }
};
