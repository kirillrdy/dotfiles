//! Real GTK widgets under Xvfb; no portal backend or public test controls.
const std = @import("std");
const c = @import("gtk");
const Dialog = @import("chooser").Dialog;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectStrings = std.testing.expectEqualStrings;
var io: std.Io = undefined;
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
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
            c.gtk_dialog_response(cast(c.GtkDialog, dialog.window), c.GTK_RESPONSE_OK);
        }
        try expectEqual(@as(?u32, 0), self.code);
    }
};
fn selectedCount(dialog: *Dialog) usize {
    const list = c.gtk_file_chooser_get_uris(dialog.chooser());
    defer c.g_slist_free(list);
    var count: usize = 0;
    var node = list;
    while (node != null) : (node = node.*.next) {
        count += 1;
        c.g_free(node.*.data);
    }
    return count;
}
fn select(dialog: *Dialog, files: []const [:0]const u8) !void {
    const deadline = c.g_get_monotonic_time() + 5_000_000;
    try expect(c.gtk_file_chooser_select_filename(dialog.chooser(), files[0]) != 0);
    while (selectedCount(dialog) == 0 and c.g_get_monotonic_time() < deadline) pump();
    while (selectedCount(dialog) != files.len and c.g_get_monotonic_time() < deadline) {
        pump();
        if (files.len > 1) c.gtk_file_chooser_select_all(dialog.chooser());
    }
    if (selectedCount(dialog) != files.len) {
        const folder = c.gtk_file_chooser_get_current_folder(dialog.chooser());
        defer c.g_free(folder);
        std.debug.print("select: expected {d} files, got {d}, folder={s}\n", .{ files.len, selectedCount(dialog), std.mem.span(folder) });
        const list = c.gtk_file_chooser_get_uris(dialog.chooser());
        defer c.g_slist_free(list);
        var node = list;
        while (node != null) : (node = node.*.next) {
            std.debug.print("selected: {s}\n", .{@as([*:0]const u8, @ptrCast(node.*.data))});
            c.g_free(node.*.data);
        }
    }
    try expectEqual(files.len, selectedCount(dialog));
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
        try expect(c.gtk_file_chooser_get_select_multiple(dialog.chooser()) != 0);
        try expectStrings("Text", std.mem.span(c.gtk_file_filter_get_name(c.gtk_file_chooser_get_filter(dialog.chooser()))));
        try expectEqual(@as(usize, 2), dialog.choices.items.len);
        try expectStrings("raw", std.mem.span(c.gtk_combo_box_get_active_id(cast(c.GtkComboBox, dialog.choices.items[0].widget))));
        try expect(c.gtk_toggle_button_get_active(cast(c.GtkToggleButton, dialog.choices.items[1].widget)) != 0);
        _ = c.gtk_combo_box_set_active_id(cast(c.GtkComboBox, dialog.choices.items[0].widget), "utf8");
        c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, dialog.choices.items[1].widget), 0);
        c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, dialog.read_only.?), 1);
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
        try expectEqual(c.GTK_FILE_CHOOSER_ACTION_SAVE, c.gtk_file_chooser_get_action(dialog.chooser()));
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
        try expectEqual(c.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER, c.gtk_file_chooser_get_action(dialog.chooser()));
        const deadline = c.g_get_monotonic_time() + 5_000_000;
        while (c.g_get_monotonic_time() < deadline) {
            const folder = c.gtk_file_chooser_get_current_folder(dialog.chooser());
            const ready = folder != null and std.mem.eql(u8, std.mem.span(folder), root);
            c.g_free(folder);
            if (ready) break;
            pump();
        }
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
        try expectEqual(c.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER, c.gtk_file_chooser_get_action(dialog.chooser()));
        c.gtk_dialog_response(cast(c.GtkDialog, dialog.window), c.GTK_RESPONSE_CANCEL);
        try expectEqual(@as(?u32, 1), done.code);
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
    // Let GTK finish cancelled file enumeration before the leak assertion.
    for (0..30) |_| pump();
    std.debug.print("PASS native file dialogs: multiple/Unicode files, filters, choices, read-only, save, collision-free multi-save, cancellation and invalid options\n", .{});
}
