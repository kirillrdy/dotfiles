//! Native file controls under the headless compositor; portal result contracts.
const std = @import("std");
const c = @import("desktop").glib;
const dbus = @import("desktop").dbus;
const variant_text = @import("desktop").dbus_text;
const Dialog = @import("desktop").chooser.Dialog;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectStrings = std.testing.expectEqualStrings;
var io: std.Io = undefined;
const cast = c.__zig.cast;
const Dict = dbus.Dict([]const u8, dbus.Value);
fn pump() void {
    while (c.g_main_context_iteration(null, 0) != 0) {}
    io.sleep(.fromMilliseconds(5), .awake) catch {};
}
/// A value from its GVariant text form.
fn parse(data_allocator: std.mem.Allocator, signature: []const u8, value: []const u8) dbus.Value {
    return variant_text.parse(data_allocator, signature, value) catch @panic("invalid fixture value");
}
fn print(data_allocator: std.mem.Allocator, value: dbus.Value) []const u8 {
    return variant_text.print(data_allocator, value) catch @panic("out of memory");
}
/// Options with `current_folder` set to `root` as a nul-terminated byte string.
const Builder = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Dict.Entry) = .empty,
    fn init(data_allocator: std.mem.Allocator, root: [:0]const u8) Builder {
        var self: Builder = .{ .allocator = data_allocator };
        self.put("current_folder", .{ .bytes = root[0 .. root.len + 1] });
        return self;
    }
    fn put(self: *Builder, key: []const u8, value: dbus.Value) void {
        self.entries.append(self.allocator, .{ .key = key, .value = value }) catch @panic("out of memory");
    }
    fn dict(self: *const Builder) Dict {
        return .{ .entries = self.entries.items };
    }
};
/// Options from their `a{sv}` text form.
fn options(data_allocator: std.mem.Allocator, value: []const u8) Dict {
    const items = parse(data_allocator, "a{sv}", value).array.items;
    const entries = data_allocator.alloc(Dict.Entry, items.len) catch @panic("out of memory");
    for (entries, items) |*entry, item| entry.* = .{ .key = item.dict_entry[0].string, .value = item.dict_entry[1].variant.* };
    return .{ .entries = entries };
}
fn lookup(result: Dict, key: []const u8) ?dbus.Value {
    for (result.entries) |entry| if (std.mem.eql(u8, entry.key, key)) return entry.value;
    return null;
}
const Done = struct {
    allocator: std.mem.Allocator,
    code: ?u32 = null,
    result: Dict = .{ .entries = &.{} },
    fn completed(data: ?*anyopaque, code: u32, result: Dict) void {
        const self = cast(Done, data);
        self.code = code;
        // Results are only borrowed for the call.
        const a = self.allocator;
        const entries = a.alloc(Dict.Entry, result.entries.len) catch @panic("out of memory");
        for (entries, result.entries) |*entry, item| entry.* = .{ .key = a.dupe(u8, item.key) catch @panic("out of memory"), .value = item.value.clone(a) catch @panic("out of memory") };
        self.result = .{ .entries = entries };
    }
    fn accept(self: *Done, dialog: *Dialog) !void {
        const deadline = c.__zig.monotonicTime() + 5_000_000;
        while (self.code == null and c.__zig.monotonicTime() < deadline) {
            pump();
            dialog.accept();
        }
        try expectEqual(@as(?u32, 0), self.code);
    }
};
fn loaded(dialog: *Dialog) !void {
    const deadline = c.__zig.monotonicTime() + 5_000_000;
    while (dialog.pending != null and c.__zig.monotonicTime() < deadline) pump();
    try expect(dialog.pending == null and dialog.listing != null);
}
fn select(dialog: *Dialog, paths: []const [:0]const u8) !void {
    try loaded(dialog);
    for (paths) |path| try dialog.selectPath(path);
}
fn uris(result: Dict) []const dbus.Value {
    return lookup(result, "uris").?.array.items;
}
fn checkUri(data_allocator: std.mem.Allocator, result: Dict, expected: [:0]const u8) !void {
    const file = c.g_file_new_for_path(expected);
    defer c.g_object_unref(file);
    const uri = c.g_file_get_uri(file);
    defer c.g_free(uri);
    var found = false;
    for (uris(result)) |item| {
        if (std.mem.eql(u8, std.mem.span(uri), item.string)) found = true;
    }
    if (!found) std.debug.print("expected URI {s}, got {s}\n", .{ std.mem.span(uri), print(data_allocator, lookup(result, "uris").?) });
    try expect(found);
}
pub fn main(init: std.process.Init) !void {
    io = init.io;
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (allocator.deinit() == .leak) @panic("file chooser allocation leak");
    const a = allocator.allocator();
    var fixture_data = std.heap.ArenaAllocator.init(a);
    defer fixture_data.deinit();
    const data_allocator = fixture_data.allocator();
    defer @import("desktop").window.deinit();
    const args = try init.minimal.args.toSlice(a);
    defer a.free(args);
    if (args.len != 2) return error.ExpectedFixtureDirectory;
    const root = try a.dupeSentinel(u8, args[1], 0);
    defer a.free(root);
    const first = try std.fmt.allocPrintSentinel(a, "{s}/one.txt", .{root}, 0);
    defer a.free(first);
    const report = try std.fmt.allocPrintSentinel(a, "{s}/report.txt", .{root}, 0);
    defer a.free(report);
    const unicode = try std.fmt.allocPrintSentinel(a, "{s}/日本語.txt", .{root}, 0);
    defer a.free(unicode);
    _ = c.g_setenv("GTK_USE_PORTAL", "0", 1);
    _ = c.g_setenv("GIO_USE_VFS", "local", 1);
    {
        var b = Builder.init(data_allocator, root);
        const current = parse(data_allocator, "(sa(us))", "('Text', [(uint32 0, '*.txt')])");
        b.put("multiple", .{ .boolean = true });
        b.put("filters", parse(data_allocator, "a(sa(us))", "[('Text', [(uint32 0, '*.txt')]), ('Images', [(uint32 1, 'image/png')])]"));
        b.put("current_filter", current);
        b.put("choices", parse(data_allocator, "a(ssa(ss)s)", "[('encoding', 'Encoding', [('utf8', 'UTF-8'), ('raw', 'Raw')], 'raw'), ('remember', 'Remember', [], 'true')]"));
        var done: Done = .{ .allocator = data_allocator };
        const dialog = try Dialog.create(a, "OpenFile", "", "Open fixture", b.dict(), &Done.completed, &done);
        defer dialog.destroy();
        try expect(dialog.multiple);
        try expectStrings("Text", dialog.currentFilter().?.name);
        try expectEqual(@as(usize, 2), dialog.choices.items.len);
        try expectStrings("raw", dialog.ui.get(dialog.choices.items[0].item).selectedId().?);
        try expect(dialog.ui.get(dialog.choices.items[1].item).checked);
        _ = dialog.ui.select(dialog.choices.items[0].item, "utf8");
        dialog.ui.setChecked(dialog.choices.items[1].item, false);
        dialog.ui.setChecked(dialog.read_only.?, true);
        try select(dialog, &.{ first, unicode, report });
        try done.accept(dialog);
        try expectEqual(@as(usize, 3), uris(done.result).len);
        try checkUri(data_allocator, done.result, first);
        try checkUri(data_allocator, done.result, unicode);
        // Values are compared through their text form, as g_variant_equal compared them.
        try expectStrings(print(data_allocator, current), print(data_allocator, lookup(done.result, "current_filter").?));
        try expect(!lookup(done.result, "writable").?.boolean);
        try expectStrings(print(data_allocator, parse(data_allocator, "a(ss)", "[('encoding', 'utf8'), ('remember', 'false')]")), print(data_allocator, lookup(done.result, "choices").?));
    }
    {
        var b = Builder.init(data_allocator, root);
        b.put("current_name", .{ .string = "native-save.txt" });
        var done: Done = .{ .allocator = data_allocator };
        const dialog = try Dialog.create(a, "SaveFile", "", "Save fixture", b.dict(), &Done.completed, &done);
        defer dialog.destroy();
        try expect(dialog.method == .save);
        try done.accept(dialog);
        const target = try std.fmt.allocPrintSentinel(a, "{s}/native-save.txt", .{root}, 0);
        defer a.free(target);
        try checkUri(data_allocator, done.result, target);
    }
    {
        var b = Builder.init(data_allocator, root);
        b.put("files", parse(data_allocator, "aay", "[b'report.txt', b'report.txt']"));
        var done: Done = .{ .allocator = data_allocator };
        const dialog = try Dialog.create(a, "SaveFiles", "", "Save files fixture", b.dict(), &Done.completed, &done);
        defer dialog.destroy();
        try expect(dialog.directory);
        try loaded(dialog);
        try done.accept(dialog);
        const one = try std.fmt.allocPrintSentinel(a, "{s}/report(1).txt", .{root}, 0);
        defer a.free(one);
        const two = try std.fmt.allocPrintSentinel(a, "{s}/report(2).txt", .{root}, 0);
        defer a.free(two);
        try checkUri(data_allocator, done.result, one);
        try checkUri(data_allocator, done.result, two);
    }
    {
        var done: Done = .{ .allocator = data_allocator };
        const dialog = try Dialog.create(a, "OpenFile", "", "Cancel fixture", options(data_allocator, "{'directory': <true>}"), &Done.completed, &done);
        defer dialog.destroy();
        try expect(dialog.directory);
        dialog.cancel();
        try expectEqual(@as(?u32, 1), done.code);
    }
    {
        // An existing output requires a second, explicit acceptance. Editing
        // the name after the warning must not retain overwrite consent.
        var b = Builder.init(data_allocator, root);
        b.put("current_name", .{ .string = "report.txt" });
        var done: Done = .{ .allocator = data_allocator };
        const dialog = try Dialog.create(a, "SaveFile", "", "Overwrite fixture", b.dict(), &Done.completed, &done);
        defer dialog.destroy();
        try loaded(dialog);
        dialog.accept();
        try expect(done.code == null);
        try expect(dialog.overwrite != null);
        dialog.ui.focusItem(dialog.name_item.?);
        try expect(dialog.ui.handleKey('a', c.__zig.control_mask));
        try expect(dialog.ui.handleKey('b', 0));
        try expect(dialog.overwrite == null);
        try dialog.ui.setText(dialog.name_item.?, "report.txt");
        dialog.accept();
        try expect(done.code == null);
        try done.accept(dialog);
        try checkUri(data_allocator, done.result, report);
    }
    {
        const left = try std.fmt.allocPrintSentinel(a, "{s}/folder-a", .{root}, 0);
        defer a.free(left);
        const right = try std.fmt.allocPrintSentinel(a, "{s}/folder-b", .{root}, 0);
        defer a.free(right);
        try std.Io.Dir.cwd().createDirPath(io, left);
        try std.Io.Dir.cwd().createDirPath(io, right);
        var b = Builder.init(data_allocator, root);
        b.put("directory", .{ .boolean = true });
        b.put("multiple", .{ .boolean = true });
        var done: Done = .{ .allocator = data_allocator };
        const dialog = try Dialog.create(a, "OpenFile", "", "Multiple folders fixture", b.dict(), &Done.completed, &done);
        defer dialog.destroy();
        try loaded(dialog);
        try dialog.selectPath(left);
        try dialog.selectPath(right);
        try done.accept(dialog);
        try expectEqual(@as(usize, 2), uris(done.result).len);
        try checkUri(data_allocator, done.result, left);
        try checkUri(data_allocator, done.result, right);
    }
    {
        const hidden = try std.fmt.allocPrintSentinel(a, "{s}/.hidden.txt", .{root}, 0);
        defer a.free(hidden);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = hidden, .data = "hidden" });
        for (0..600) |index| {
            const path = try std.fmt.allocPrint(a, "{s}/page-{d}.txt", .{ root, index });
            defer a.free(path);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "page" });
        }
        const b = Builder.init(data_allocator, root);
        var done: Done = .{ .allocator = data_allocator };
        const dialog = try Dialog.create(a, "OpenFile", "", "Scrolling fixture", b.dict(), &Done.completed, &done);
        defer dialog.destroy();
        try loaded(dialog);
        try expect(dialog.view.count > 600);
        var second: usize = 0;
        var tenth: usize = 0;
        for (dialog.listing.?.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.name, "page-2.txt")) second = index;
            if (std.mem.eql(u8, entry.name, "page-10.txt")) tenth = index;
        }
        try expect(second < tenth);
        try expect(dialog.rows.items.len <= 512);
        dialog.scrollBy(100000);
        try expect(dialog.view.offset > 0);
        try expect(dialog.rows.items[0].ordinal > 0);
        try expect(dialog.rows.items.len <= 512);
        try expect(dialog.ui.shortcut.?(dialog, 0xff57, 0)); // End reveals and selects the last file.
        try expectEqual(dialog.view.count - 1, dialog.rows.items[dialog.rows.items.len - 1].ordinal);
        dialog.ui.activate(dialog.view.toggle_view);
        try expect(!dialog.view.grid and dialog.view.columns == 1);
        try expectEqual(@as(f64, 52), dialog.ui.get(dialog.rows.items[0].item).bounds.height);
        dialog.ui.activate(dialog.view.toggle_view);
        try expect(dialog.view.grid);
        try expect(dialog.ui.shortcut.?(dialog, 'f', c.__zig.control_mask));
        try dialog.ui.setText(dialog.view.query, "PAGE-599");
        dialog.ui.changed(dialog, dialog.view.query);
        try expectEqual(@as(usize, 1), dialog.view.count);
        try expect(dialog.ui.shortcut.?(dialog, 0xff1b, 0));
        try expect(dialog.view.count > 600);
        try std.testing.expectError(error.NoSelection, dialog.selectPath(hidden));
        _ = dialog.ui.shortcut.?(dialog, 'h', c.__zig.control_mask);
        try expectEqual(@as(f64, 0), dialog.view.offset);
        try dialog.selectPath(first);
        try dialog.selectPath(hidden);
        try done.accept(dialog);
        try expectEqual(@as(usize, 1), uris(done.result).len);
        try checkUri(data_allocator, done.result, hidden);
    }
    {
        const b = Builder.init(data_allocator, root);
        var done: Done = .{ .allocator = data_allocator };
        // Both scans may finish after the dialog has been destroyed. Neither
        // may touch its controls or deliver a portal response.
        const dialog = try Dialog.create(a, "OpenFile", "", "Cancelled scan fixture", b.dict(), &Done.completed, &done);
        try dialog.navigate(root);
        dialog.destroy();
        for (0..100) |_| pump();
        try expect(done.code == null);
    }
    {
        var done: Done = .{ .allocator = data_allocator };
        try std.testing.expectError(error.InvalidFileName, Dialog.create(a, "OpenFile", "", "Invalid", options(data_allocator, "{'current_folder': <[byte 47, 116, 109, 112]>}"), &Done.completed, &done));
        try std.testing.expectError(error.InvalidFileFilter, Dialog.create(a, "OpenFile", "", "Invalid", options(data_allocator, "{'filters': <[('Invalid', [(uint32 2, '*')])]>}"), &Done.completed, &done));
        try std.testing.expectError(error.InvalidFileChoice, Dialog.create(a, "OpenFile", "", "Invalid", options(data_allocator, "{'choices': <[('same', 'First', @a(ss) [], 'true'), ('same', 'Second', @a(ss) [], 'false')]>}"), &Done.completed, &done));
    }
    // Drain cancelled asynchronous enumeration before the leak assertion.
    for (0..30) |_| pump();
    std.debug.print("PASS native file dialogs: Unicode, filters, choices, read-only, overwrite consent, multi-save, multiple folders, virtual scrolling, keyboard selection, grid/list, search, hidden files, cancelled scans and invalid options\n", .{});
}
