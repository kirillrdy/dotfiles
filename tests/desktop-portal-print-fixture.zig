//! Real file-backend jobs, with no printer or print server.
const std = @import("std");
const c = @import("gtk");
const libc = @import("libc");
const printing = @import("printing");
const expect = std.testing.expect;
var io: std.Io = undefined;
fn cast(comptime T: type, value: anytype) *T {
    return @ptrCast(@alignCast(value));
}
fn pump() void {
    while (c.g_main_context_iteration(null, 0) != 0) {}
    io.sleep(.fromMilliseconds(5), .awake) catch {};
}
fn parse(value: [*:0]const u8) *c.GVariant {
    return c.g_variant_take_ref(c.g_variant_parse(null, value, null, null, null)).?;
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
    fn wait(self: *Done, code: u32) !void {
        const deadline = c.g_get_monotonic_time() + 8_000_000;
        while (self.code == null and c.g_get_monotonic_time() < deadline) pump();
        try std.testing.expectEqual(@as(?u32, code), self.code);
    }
    fn accept(self: *Done, operation: *printing.Operation) !void {
        const button = c.gtk_dialog_get_widget_for_response(cast(c.GtkDialog, operation.window), c.GTK_RESPONSE_OK);
        const deadline = c.g_get_monotonic_time() + 8_000_000;
        while (c.gtk_widget_get_sensitive(button) == 0 and c.g_get_monotonic_time() < deadline) pump();
        try expect(c.gtk_widget_get_sensitive(button) != 0);
        c.gtk_dialog_response(cast(c.GtkDialog, operation.window), c.GTK_RESPONSE_OK);
        try self.wait(0);
    }
    fn token(self: *Done) u32 {
        const value = c.g_variant_lookup_value(self.result, "token", null);
        defer c.g_variant_unref(value);
        return c.g_variant_get_uint32(value);
    }
};
fn initial(uri: [:0]const u8) *c.GVariant {
    const b = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
    defer c.g_variant_builder_unref(b);
    c.g_variant_builder_add(b, "{sv}", @as([*:0]const u8, "printer"), c.g_variant_new("s", @as([*:0]const u8, "Print to File")));
    c.g_variant_builder_add(b, "{sv}", @as([*:0]const u8, "output-uri"), c.g_variant_new("s", uri.ptr));
    c.g_variant_builder_add(b, "{sv}", @as([*:0]const u8, "output-file-format"), c.g_variant_new("s", @as([*:0]const u8, "pdf")));
    return c.g_variant_take_ref(c.g_variant_builder_end(b)).?;
}
fn tokenOptions(token: u32) *c.GVariant {
    const b = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
    defer c.g_variant_builder_unref(b);
    c.g_variant_builder_add(b, "{sv}", @as([*:0]const u8, "token"), c.g_variant_new("u", token));
    return c.g_variant_take_ref(c.g_variant_builder_end(b)).?;
}
const document = "%PDF-1.4\n% native print fixture: 日本語\n\x00\xff\n%%EOF\n";
pub fn main(init: std.process.Init) !void {
    io = init.io;
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (allocator.deinit() == .leak) @panic("print allocation leak");
    const a = allocator.allocator();
    const args = try init.minimal.args.toSlice(a);
    defer a.free(args);
    if (args.len != 2) return error.ExpectedFixtureDirectory;
    const source = try std.fmt.allocPrintSentinel(a, "{s}/source.pdf", .{args[1]}, 0);
    defer a.free(source);
    const target = try std.fmt.allocPrintSentinel(a, "{s}/native.pdf", .{args[1]}, 0);
    defer a.free(target);
    const file = c.g_file_new_for_path(target);
    defer c.g_object_unref(file);
    const uri = c.g_file_get_uri(file);
    defer c.g_free(uri);
    const writer = libc.open(source, libc.O_WRONLY | libc.O_CREAT | libc.O_TRUNC | libc.O_CLOEXEC, @as(c_uint, 0o600));
    try expect(writer >= 0);
    try expect(libc.write(writer, document.ptr, document.len) == document.len);
    try expect(libc.close(writer) == 0);
    const fd = libc.open(source, libc.O_RDONLY | libc.O_CLOEXEC);
    try expect(fd >= 0);
    defer _ = libc.close(fd);
    const descriptors = c.g_unix_fd_list_new();
    defer c.g_object_unref(descriptors);
    try expect(c.g_unix_fd_list_append(descriptors, fd, null) == 0);
    const service = try printing.Service.create(a);
    defer service.destroy();
    const settings = initial(std.mem.span(uri));
    defer c.g_variant_unref(settings);
    const page = parse("{'Name': <'custom'>, 'DisplayName': <'Fixture paper'>, 'Width': <210.0>, 'Height': <297.0>, 'MarginTop': <12.0>, 'Orientation': <'landscape'>}");
    defer c.g_variant_unref(page);
    const options = parse("{'supported_output_file_formats': <['pdf']>, 'has_current_page': <true>, 'has_selected_pages': <true>, 'accept_label': <'_Go'>}");
    defer c.g_variant_unref(options);
    const no_options = parse("@a{sv} {}");
    defer c.g_variant_unref(no_options);
    {
        var prepared: Done = .{};
        defer prepared.deinit();
        const dialog = try printing.Operation.create(service, ":owner", "", "Prepare native print", settings, page, options, null, null, &Done.completed, &prepared);
        defer dialog.destroy();
        try prepared.accept(dialog);
        try expect(prepared.token() != 0);
        const returned = c.g_variant_lookup_value(prepared.result, "page-setup", null);
        defer c.g_variant_unref(returned);
        const orientation = c.g_variant_lookup_value(returned, "Orientation", null);
        defer c.g_variant_unref(orientation);
        try std.testing.expectEqualStrings("landscape", std.mem.span(c.g_variant_get_string(orientation, null)));
        const opts = tokenOptions(prepared.token());
        defer c.g_variant_unref(opts);
        var done: Done = .{};
        defer done.deinit();
        try std.testing.expectError(error.InvalidPrintToken, printing.Operation.create(service, ":other", "", "Foreign print", null, null, opts, descriptors, 0, &Done.completed, &done));
        const job = try printing.Operation.create(service, ":owner", "", "Native print", null, null, opts, descriptors, 0, &Done.completed, &done);
        defer job.destroy();
        try expect(job.window == null);
        try done.wait(0);
        var contents: [*c]u8 = null;
        var size: usize = 0;
        try expect(c.g_file_get_contents(target, &contents, &size, null) != 0);
        defer c.g_free(contents);
        try std.testing.expectEqualStrings(document, contents[0..size]);
        try expect(std.c.unlink(target) == 0);
        try std.testing.expectError(error.InvalidPrintToken, printing.Operation.create(service, ":owner", "", "Reused print", null, null, opts, descriptors, 0, &Done.completed, &done));
    }
    {
        var done: Done = .{};
        defer done.deinit();
        const dialog = try printing.Operation.create(service, ":owner", "", "Cancel direct print", null, null, no_options, descriptors, 0, &Done.completed, &done);
        defer dialog.destroy();
        c.gtk_dialog_response(cast(c.GtkDialog, dialog.window), c.GTK_RESPONSE_CANCEL);
        try done.wait(1);
    }
    {
        var done: Done = .{};
        defer done.deinit();
        const dialog = try printing.Operation.create(service, ":direct", "", "Direct native print", settings, null, options, descriptors, 0, &Done.completed, &done);
        defer dialog.destroy();
        try done.accept(dialog);
        try expect(std.c.unlink(target) == 0);
    }
    {
        var prepared: Done = .{};
        defer prepared.deinit();
        const dialog = try printing.Operation.create(service, ":expire", "", "Expiring settings", settings, null, options, null, null, &Done.completed, &prepared);
        defer dialog.destroy();
        try prepared.accept(dialog);
        service.prepared.items[0].expires = 0;
        const opts = tokenOptions(prepared.token());
        defer c.g_variant_unref(opts);
        var done: Done = .{};
        try std.testing.expectError(error.InvalidPrintToken, printing.Operation.create(service, ":expire", "", "Expired print", null, null, opts, descriptors, 0, &Done.completed, &done));
        try expect(service.prepared.items.len == 0);
    }
    {
        var prepared: Done = .{};
        defer prepared.deinit();
        const dialog = try printing.Operation.create(service, ":failure", "", "Failing job settings", settings, null, options, null, null, &Done.completed, &prepared);
        defer dialog.destroy();
        try prepared.accept(dialog);
        const params = service.prepared.items[0];
        c.g_object_unref(params.settings);
        const broken = initial("file:///nonexistent-fixture-directory/output.pdf");
        defer c.g_variant_unref(broken);
        params.settings = c.gtk_print_settings_new_from_gvariant(broken).?;
        const opts = tokenOptions(prepared.token());
        defer c.g_variant_unref(opts);
        var done: Done = .{};
        defer done.deinit();
        const job = try printing.Operation.create(service, ":failure", "", "Failed native job", null, null, opts, descriptors, 0, &Done.completed, &done);
        defer job.destroy();
        try done.wait(2);
    }
    for (0..30) |_| pump();
    std.debug.print("PASS native print prepare/settings, caller-owned single-use tokens, FD spooling, cancellation, expiration and job failure\n", .{});
}
