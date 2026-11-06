//! Native file controls under the headless compositor; portal result contracts.
const std = @import("std");
const c = @import("desktop").gtk;
const Dialog = @import("desktop").chooser.Dialog;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectStrings = std.testing.expectEqualStrings;
var io: std.Io = undefined;
const cast = c.__zig.cast;
fn pump() void {
    while (c.g_main_context_iteration(null, 0) != 0) {}
    io.sleep(.fromMilliseconds(5), .awake) catch {};
}
fn parse(value: [*:0]const u8) *c.GVariant {
    return c.g_variant_take_ref(c.g_variant_parse(null, value, null, null, null)).?;
}
fn optionBuilder(root: [:0]const u8) *c.GVariantBuilder {
    const value = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}"))).?;
    c.g_variant_builder_add(value, "{sv}", @as([*:0]const u8, "current_folder"), c.g_variant_new_fixed_array(@ptrCast(@as([*:0]const u8, "y")), root.ptr, root.len + 1, 1));
    return value;
}
const Done = struct {
    code: ?u32 = null,
    result: ?*c.GVariant = null,
    fn completed(data: ?*anyopaque, code: u32, result: ?*c.GVariant) void {
        const self = cast(Done, data);
        self.code = code;
        self.result = c.g_variant_take_ref(result);
    }
    fn deinit(self: *Done) void {
        if (self.result != null) c.g_variant_unref(self.result);
    }
    fn accept(self: *Done, dialog: *Dialog) !void {
        const deadline = c.g_get_monotonic_time() + 5_000_000;
        while (self.code == null and c.g_get_monotonic_time() < deadline) {
            pump();
            dialog.accept();
        }
        try expectEqual(@as(?u32, 0), self.code);
    }
};
fn loaded(dialog: *Dialog) !void {
    const deadline = c.g_get_monotonic_time() + 5_000_000;
    while (dialog.pending != null and c.g_get_monotonic_time() < deadline) pump();
    try expect(dialog.pending == null and dialog.listing != null);
}
fn select(dialog: *Dialog, paths: []const [:0]const u8) !void {
    try loaded(dialog);
    for (paths) |path| try dialog.selectPath(path);
}
fn uris(result: ?*c.GVariant) *c.GVariant {
    return c.g_variant_lookup_value(result, "uris", @ptrCast(@as([*:0]const u8, "as"))).?;
}
fn checkUri(result: ?*c.GVariant, expected: [:0]const u8) !void {
    const values = uris(result);
    defer c.g_variant_unref(values);
    const file = c.g_file_new_for_path(expected);
    defer c.g_object_unref(file);
    const uri = c.g_file_get_uri(file);
    defer c.g_free(uri);
    var found = false;
    for (0..c.g_variant_n_children(values)) |i| {
        const item = c.g_variant_get_child_value(values, i);
        defer c.g_variant_unref(item);
        if (std.mem.eql(u8, std.mem.span(uri), std.mem.span(c.g_variant_get_string(item, null)))) found = true;
    }
    if (!found) {
        const actual = c.g_variant_print(values, 1);
        defer c.g_free(actual);
        std.debug.print("expected URI {s}, got {s}\n", .{ std.mem.span(uri), std.mem.span(actual) });
    }
    try expect(found);
}
pub fn main(init: std.process.Init) !void {
    io = init.io;
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (allocator.deinit() == .leak) @panic("file chooser allocation leak");
    const a = allocator.allocator();
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
    try expect(c.gtk_init_check(null, null) != 0);
    {
        const b = optionBuilder(root);
        defer c.g_variant_builder_unref(b);
        const filters = parse("[('Text', [(uint32 0, '*.txt')]), ('Images', [(uint32 1, 'image/png')])]");
        defer c.g_variant_unref(filters);
        const current = parse("('Text', [(uint32 0, '*.txt')])");
        defer c.g_variant_unref(current);
        const choices = parse("[('encoding', 'Encoding', [('utf8', 'UTF-8'), ('raw', 'Raw')], 'raw'), ('remember', 'Remember', [], 'true')]");
        defer c.g_variant_unref(choices);
        c.g_variant_builder_add(b, "{sv}", @as([*:0]const u8, "multiple"), c.g_variant_new("b", @as(c_int, 1)));
        c.g_variant_builder_add(b, "{sv}", @as([*:0]const u8, "filters"), filters);
        c.g_variant_builder_add(b, "{sv}", @as([*:0]const u8, "current_filter"), current);
        c.g_variant_builder_add(b, "{sv}", @as([*:0]const u8, "choices"), choices);
        const options = c.g_variant_take_ref(c.g_variant_builder_end(b)).?;
        defer c.g_variant_unref(options);
        var done: Done = .{};
        defer done.deinit();
        const dialog = try Dialog.create(a, "OpenFile", "", "Open fixture", options, &Done.completed, &done);
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
        const values = uris(done.result);
        defer c.g_variant_unref(values);
        try expectEqual(@as(usize, 3), c.g_variant_n_children(values));
        try checkUri(done.result, first);
        try checkUri(done.result, unicode);
        const returned_filter = c.g_variant_lookup_value(done.result, "current_filter", null);
        defer c.g_variant_unref(returned_filter);
        try expect(c.g_variant_equal(returned_filter, current) != 0);
        const writable = c.g_variant_lookup_value(done.result, "writable", null);
        defer c.g_variant_unref(writable);
        try expect(c.g_variant_get_boolean(writable) == 0);
        const returned = c.g_variant_lookup_value(done.result, "choices", null);
        defer c.g_variant_unref(returned);
        const expected = parse("[('encoding', 'utf8'), ('remember', 'false')]");
        defer c.g_variant_unref(expected);
        try expect(c.g_variant_equal(returned, expected) != 0);
    }
    {
        const b = optionBuilder(root);
        defer c.g_variant_builder_unref(b);
        c.g_variant_builder_add(b, "{sv}", @as([*:0]const u8, "current_name"), c.g_variant_new("s", @as([*:0]const u8, "native-save.txt")));
        const options = c.g_variant_take_ref(c.g_variant_builder_end(b)).?;
        defer c.g_variant_unref(options);
        var done: Done = .{};
        defer done.deinit();
        const dialog = try Dialog.create(a, "SaveFile", "", "Save fixture", options, &Done.completed, &done);
        defer dialog.destroy();
        try expect(dialog.method == .save);
        try done.accept(dialog);
        const target = try std.fmt.allocPrintSentinel(a, "{s}/native-save.txt", .{root}, 0);
        defer a.free(target);
        try checkUri(done.result, target);
    }
    {
        const b = optionBuilder(root);
        defer c.g_variant_builder_unref(b);
        const files = parse("[b'report.txt', b'report.txt']");
        defer c.g_variant_unref(files);
        c.g_variant_builder_add(b, "{sv}", @as([*:0]const u8, "files"), files);
        const options = c.g_variant_take_ref(c.g_variant_builder_end(b)).?;
        defer c.g_variant_unref(options);
        var done: Done = .{};
        defer done.deinit();
        const dialog = try Dialog.create(a, "SaveFiles", "", "Save files fixture", options, &Done.completed, &done);
        defer dialog.destroy();
        try expect(dialog.directory);
        try loaded(dialog);
        try done.accept(dialog);
        const one = try std.fmt.allocPrintSentinel(a, "{s}/report(1).txt", .{root}, 0);
        defer a.free(one);
        const two = try std.fmt.allocPrintSentinel(a, "{s}/report(2).txt", .{root}, 0);
        defer a.free(two);
        try checkUri(done.result, one);
        try checkUri(done.result, two);
    }
    {
        const options = parse("{'directory': <true>}");
        defer c.g_variant_unref(options);
        var done: Done = .{};
        defer done.deinit();
        const dialog = try Dialog.create(a, "OpenFile", "", "Cancel fixture", options, &Done.completed, &done);
        defer dialog.destroy();
        try expect(dialog.directory);
        dialog.cancel();
        try expectEqual(@as(?u32, 1), done.code);
    }
    {
        // An existing output requires a second, explicit acceptance. Editing
        // the name after the warning must not retain overwrite consent.
        const b = optionBuilder(root);
        defer c.g_variant_builder_unref(b);
        c.g_variant_builder_add(b, "{sv}", @as([*:0]const u8, "current_name"), c.g_variant_new("s", @as([*:0]const u8, "report.txt")));
        const options = c.g_variant_take_ref(c.g_variant_builder_end(b)).?;
        defer c.g_variant_unref(options);
        var done: Done = .{};
        defer done.deinit();
        const dialog = try Dialog.create(a, "SaveFile", "", "Overwrite fixture", options, &Done.completed, &done);
        defer dialog.destroy();
        try loaded(dialog);
        dialog.accept();
        try expect(done.code == null);
        try expect(dialog.overwrite != null);
        dialog.ui.focusItem(dialog.name_item.?);
        try expect(dialog.ui.handleKey('a', c.GDK_CONTROL_MASK));
        try expect(dialog.ui.handleKey('b', 0));
        try expect(dialog.overwrite == null);
        try dialog.ui.setText(dialog.name_item.?, "report.txt");
        dialog.accept();
        try expect(done.code == null);
        try done.accept(dialog);
        try checkUri(done.result, report);
    }
    {
        const left = try std.fmt.allocPrintSentinel(a, "{s}/folder-a", .{root}, 0);
        defer a.free(left);
        const right = try std.fmt.allocPrintSentinel(a, "{s}/folder-b", .{root}, 0);
        defer a.free(right);
        try std.Io.Dir.cwd().createDirPath(io, left);
        try std.Io.Dir.cwd().createDirPath(io, right);
        const b = optionBuilder(root);
        defer c.g_variant_builder_unref(b);
        c.g_variant_builder_add(b, "{sv}", @as([*:0]const u8, "directory"), c.g_variant_new("b", @as(c_int, 1)));
        c.g_variant_builder_add(b, "{sv}", @as([*:0]const u8, "multiple"), c.g_variant_new("b", @as(c_int, 1)));
        const options = c.g_variant_take_ref(c.g_variant_builder_end(b)).?;
        defer c.g_variant_unref(options);
        var done: Done = .{};
        defer done.deinit();
        const dialog = try Dialog.create(a, "OpenFile", "", "Multiple folders fixture", options, &Done.completed, &done);
        defer dialog.destroy();
        try loaded(dialog);
        try dialog.selectPath(left);
        try dialog.selectPath(right);
        try done.accept(dialog);
        const values = uris(done.result);
        defer c.g_variant_unref(values);
        try expectEqual(@as(usize, 2), c.g_variant_n_children(values));
        try checkUri(done.result, left);
        try checkUri(done.result, right);
    }
    {
        const hidden = try std.fmt.allocPrintSentinel(a, "{s}/.hidden.txt", .{root}, 0);
        defer a.free(hidden);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = hidden, .data = "hidden" });
        for (0..40) |index| {
            const path = try std.fmt.allocPrint(a, "{s}/page-{d}.txt", .{ root, index });
            defer a.free(path);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "page" });
        }
        const b = optionBuilder(root);
        defer c.g_variant_builder_unref(b);
        const options = c.g_variant_take_ref(c.g_variant_builder_end(b)).?;
        defer c.g_variant_unref(options);
        var done: Done = .{};
        defer done.deinit();
        const dialog = try Dialog.create(a, "OpenFile", "", "Paging fixture", options, &Done.completed, &done);
        defer dialog.destroy();
        try loaded(dialog);
        try expect(dialog.ui.get(dialog.next_item).enabled);
        dialog.ui.activate(dialog.next_item);
        try expectEqual(@as(usize, 1), dialog.page);
        try expect(dialog.ui.get(dialog.previous_item).enabled);
        try std.testing.expectError(error.NoSelection, dialog.selectPath(hidden));
        dialog.ui.activate(dialog.hidden_item);
        try expectEqual(@as(usize, 0), dialog.page);
        try dialog.selectPath(first);
        try dialog.selectPath(hidden);
        try done.accept(dialog);
        const values = uris(done.result);
        defer c.g_variant_unref(values);
        try expectEqual(@as(usize, 1), c.g_variant_n_children(values));
        try checkUri(done.result, hidden);
    }
    {
        const b = optionBuilder(root);
        defer c.g_variant_builder_unref(b);
        const options = c.g_variant_take_ref(c.g_variant_builder_end(b)).?;
        defer c.g_variant_unref(options);
        var done: Done = .{};
        // Both scans may finish after the dialog has been destroyed. Neither
        // may touch its controls or deliver a portal response.
        const dialog = try Dialog.create(a, "OpenFile", "", "Cancelled scan fixture", options, &Done.completed, &done);
        try dialog.navigate(root);
        dialog.destroy();
        for (0..100) |_| pump();
        try expect(done.code == null);
    }
    {
        const invalid = parse("{'current_folder': <[byte 47, 116, 109, 112]>}");
        defer c.g_variant_unref(invalid);
        var done: Done = .{};
        try std.testing.expectError(error.InvalidFileName, Dialog.create(a, "OpenFile", "", "Invalid", invalid, &Done.completed, &done));
        const filter = parse("{'filters': <[('Invalid', [(uint32 2, '*')])]>}");
        defer c.g_variant_unref(filter);
        try std.testing.expectError(error.InvalidFileFilter, Dialog.create(a, "OpenFile", "", "Invalid", filter, &Done.completed, &done));
        const choice = parse("{'choices': <[('same', 'First', @a(ss) [], 'true'), ('same', 'Second', @a(ss) [], 'false')]>}");
        defer c.g_variant_unref(choice);
        try std.testing.expectError(error.InvalidFileChoice, Dialog.create(a, "OpenFile", "", "Invalid", choice, &Done.completed, &done));
    }
    // Drain cancelled asynchronous enumeration before the leak assertion.
    for (0..30) |_| pump();
    std.debug.print("PASS native file dialogs: Unicode, filters, choices, read-only, overwrite consent, multi-save, multiple folders, paging, hidden files, cancelled scans and invalid options\n", .{});
}
