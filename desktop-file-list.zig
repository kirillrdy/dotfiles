//! Local file enumeration and portal filters. No GTK widget or filter objects.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const cast = c.__zig.cast;
const Enumerator = opaque {};
const Info = opaque {};
extern fn g_file_enumerate_children_async(?*c.GFile, [*:0]const u8, c_uint, c_int, ?*c.GCancellable, c.GAsyncReadyCallback, ?*anyopaque) void;
extern fn g_file_enumerate_children_finish(?*c.GFile, ?*c.GAsyncResult, *?*c.GError) ?*Enumerator;
extern fn g_file_enumerator_next_files_async(*Enumerator, c_int, c_int, ?*c.GCancellable, c.GAsyncReadyCallback, ?*anyopaque) void;
extern fn g_file_enumerator_next_files_finish(*Enumerator, ?*c.GAsyncResult, *?*c.GError) ?*c.GList;
extern fn g_file_info_get_name(*Info) [*:0]const u8;
extern fn g_file_info_get_display_name(*Info) [*:0]const u8;
extern fn g_file_info_get_file_type(*Info) c_uint;
extern fn g_file_info_get_content_type(*Info) ?[*:0]const u8;
extern fn g_file_info_get_is_hidden(*Info) c_int;
extern fn g_file_info_get_size(*Info) i64;
extern fn g_file_info_get_attribute_uint64(*Info, [*:0]const u8) u64;
extern fn g_content_type_is_a([*:0]const u8, [*:0]const u8) c_int;
extern fn g_content_type_from_mime_type([*:0]const u8) ?[*:0]u8;
extern fn g_pattern_match_simple([*:0]const u8, [*:0]const u8) c_int;
extern fn g_utf8_collate_key_for_filename([*:0]const u8, isize) [*:0]u8;

pub const Entry = struct {
    name: [:0]const u8,
    label: [:0]const u8,
    content_type: ?[:0]const u8,
    directory: bool,
    hidden: bool,
    selected: bool = false,
    size: u64 = 0,
    modified: u64 = 0,
    sort_key: [:0]const u8 = "",
};
pub const Rule = struct { mime: bool, pattern: [:0]const u8 };
pub fn matches(entry: Entry, rules: []const Rule) bool {
    if (entry.directory or rules.len == 0) return true;
    for (rules) |rule| {
        if (!rule.mime) {
            if (g_pattern_match_simple(rule.pattern, entry.name) != 0) return true;
        } else if (entry.content_type) |content_type| {
            const requested = g_content_type_from_mime_type(rule.pattern) orelse continue;
            defer c.g_free(requested);
            if (g_content_type_is_a(content_type, requested) != 0) return true;
        }
    }
    return false;
}

/// A scan owns its strings and remains alive until its final callback. Cancellation
/// still invokes completion, so callers can release their asynchronous reference.
pub const Scan = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    cancellable: *c.GCancellable,
    enumerator: ?*Enumerator = null,
    context: ?*anyopaque,
    completed: *const fn (?*anyopaque, *Scan, ?anyerror) void,
    pub fn start(allocator: std.mem.Allocator, path: [:0]const u8, context: ?*anyopaque, completed: *const fn (?*anyopaque, *Scan, ?anyerror) void) !*Scan {
        const self = try allocator.create(Scan);
        self.* = .{ .allocator = allocator, .arena = .init(allocator), .cancellable = c.g_cancellable_new().?, .context = context, .completed = completed };
        const directory = c.g_file_new_for_path(path).?;
        defer c.g_object_unref(directory);
        g_file_enumerate_children_async(directory, "standard::name,standard::display-name,standard::type,standard::content-type,standard::is-hidden,standard::size,time::modified", 0, 0, self.cancellable, &opened, self);
        return self;
    }
    pub fn cancel(self: *Scan) void {
        c.g_cancellable_cancel(self.cancellable);
    }
    pub fn destroy(self: *Scan) void {
        if (self.enumerator) |enumerator| c.g_object_unref(enumerator);
        c.g_object_unref(self.cancellable);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    fn opened(source: ?*c.GObject, result: ?*c.GAsyncResult, ptr: ?*anyopaque) callconv(.c) void {
        const self = cast(Scan, ptr);
        var failure: ?*c.GError = null;
        self.enumerator = g_file_enumerate_children_finish(@ptrCast(source), result, &failure);
        if (failure) |err| {
            c.g_error_free(err);
            self.completed(self.context, self, error.DirectoryUnavailable);
            return;
        }
        self.next();
    }
    fn next(self: *Scan) void {
        g_file_enumerator_next_files_async(self.enumerator.?, 128, 0, self.cancellable, &received, self);
    }
    fn less(_: void, left: Entry, right: Entry) bool {
        if (left.directory != right.directory) return left.directory;
        if (left.sort_key.len > 0 and right.sort_key.len > 0) return std.mem.lessThan(u8, left.sort_key, right.sort_key);
        return std.ascii.lessThanIgnoreCase(left.name, right.name);
    }
    fn received(source: ?*c.GObject, result: ?*c.GAsyncResult, ptr: ?*anyopaque) callconv(.c) void {
        const self = cast(Scan, ptr);
        var failure: ?*c.GError = null;
        const list = g_file_enumerator_next_files_finish(@ptrCast(source.?), result, &failure);
        defer {
            var node = list;
            while (node) |item| : (node = item.next) c.g_object_unref(item.data);
            c.g_list_free(list);
        }
        if (failure) |err| {
            c.g_error_free(err);
            self.completed(self.context, self, error.DirectoryUnavailable);
            return;
        }
        if (list == null) {
            std.mem.sort(Entry, self.entries.items, {}, less);
            self.completed(self.context, self, null);
            return;
        }
        var node = list;
        while (node) |item| : (node = item.next) {
            const info = cast(Info, item.data);
            const a = self.arena.allocator();
            const name = a.dupeSentinel(u8, std.mem.span(g_file_info_get_name(info)), 0) catch {
                self.completed(self.context, self, error.OutOfMemory);
                return;
            };
            const label = a.dupeSentinel(u8, std.mem.span(g_file_info_get_display_name(info)), 0) catch {
                self.completed(self.context, self, error.OutOfMemory);
                return;
            };
            const content_type = if (g_file_info_get_content_type(info)) |value| a.dupeSentinel(u8, std.mem.span(value), 0) catch {
                self.completed(self.context, self, error.OutOfMemory);
                return;
            } else null;
            const key = g_utf8_collate_key_for_filename(label, -1);
            defer c.g_free(key);
            const sort_key = a.dupeSentinel(u8, std.mem.span(key), 0) catch {
                self.completed(self.context, self, error.OutOfMemory);
                return;
            };
            self.entries.append(a, .{ .name = name, .label = label, .content_type = content_type, .directory = g_file_info_get_file_type(info) == 2, .hidden = g_file_info_get_is_hidden(info) != 0, .size = @intCast(@max(0, g_file_info_get_size(info))), .modified = g_file_info_get_attribute_uint64(info, "time::modified"), .sort_key = sort_key }) catch {
                self.completed(self.context, self, error.OutOfMemory);
                return;
            };
            // A bounded model avoids unbounded allocations from huge directories.
            if (self.entries.items.len >= 65536) {
                self.completed(self.context, self, error.DirectoryTooLarge);
                return;
            }
        }
        self.next();
    }
};

test "file filters preserve directories and combine glob and MIME rules" {
    const expect = std.testing.expect;
    const entry: Entry = .{ .name = "日本語.txt", .label = "日本語.txt", .content_type = "text/plain", .directory = false, .hidden = false };
    try expect(matches(entry, &.{}));
    try expect(matches(entry, &.{.{ .mime = false, .pattern = "*.txt" }}));
    try expect(!matches(entry, &.{.{ .mime = false, .pattern = "*.png" }}));
    try expect(matches(entry, &.{ .{ .mime = false, .pattern = "*.png" }, .{ .mime = true, .pattern = "text/plain" } }));
    var folder = entry;
    folder.directory = true;
    try expect(matches(folder, &.{.{ .mime = false, .pattern = "*.png" }}));
}
