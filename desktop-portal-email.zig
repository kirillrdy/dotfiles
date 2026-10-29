//! Compose mail through the configured mailto handler, without a portal backend.
const std = @import("std");
const c = @import("gtk");
const libc = @import("libc");

fn option(options: *c.GVariant, key: [*:0]const u8, signature: [:0]const u8) !?*c.GVariant {
    const value = c.g_variant_lookup_value(options, key, null) orelse return null;
    if (!std.mem.eql(u8, std.mem.span(c.g_variant_get_type_string(value)), signature)) {
        c.g_variant_unref(value);
        return error.InvalidEmailOption;
    }
    return value;
}
fn text(value: ?*c.GVariant) [:0]const u8 {
    return std.mem.span(c.g_variant_get_string(value, null));
}
// The HTML email input syntax used by the public portal, including single-label
// domains. Quoted mailboxes and display-name forms are not part of this syntax.
fn validAddress(address: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, address, '@') orelse return false;
    if (at == 0) return false;
    for (address[0..at]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", ch) == null) return false;
    }
    var labels = std.mem.splitScalar(u8, address[at + 1 ..], '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or !std.ascii.isAlphanumeric(label[0]) or !std.ascii.isAlphanumeric(label[label.len - 1])) return false;
        for (label) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    }
    return true;
}
const Uri = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    fn append(self: *Uri, value: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, value);
    }
    fn escaped(self: *Uri, value: []const u8, address: bool) !void {
        const hex = "0123456789ABCDEF";
        for (value) |ch| {
            if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~", ch) != null or (address and ch == '@')) {
                try self.bytes.append(self.allocator, ch);
            } else try self.append(&.{ '%', hex[ch >> 4], hex[ch & 15] });
        }
    }
    fn recipient(self: *Uri, address: []const u8) !void {
        if (!validAddress(address)) return error.InvalidEmailAddress;
        try self.escaped(address, true);
    }
    fn recipients(self: *Uri, values: *c.GVariant, comma: bool) !void {
        for (0..c.g_variant_n_children(values)) |index| {
            const value = c.g_variant_get_child_value(values, index);
            defer c.g_variant_unref(value);
            if (comma or index > 0) try self.append(",");
            try self.recipient(text(value));
        }
    }
};

fn fileStat(fd: c_int) !std.os.linux.Statx {
    var result: std.os.linux.Statx = undefined;
    if (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .INO = true }, &result) != 0 or !result.mask.TYPE or !result.mask.INO) return error.InvalidAttachment;
    return result;
}

fn attachmentUri(allocator: std.mem.Allocator, descriptors: ?*c.GUnixFDList, handle: c_int) ![:0]const u8 {
    const list = descriptors orelse return error.MissingFileDescriptor;
    if (handle < 0 or handle >= c.g_unix_fd_list_get_length(list)) return error.InvalidFileDescriptor;
    const fd = c.g_unix_fd_list_get(list, handle, null);
    if (fd < 0) return error.InvalidFileDescriptor;
    defer _ = libc.close(fd);
    const original = try fileStat(fd);
    if (original.mode & std.c.S.IFMT != std.c.S.IFREG) return error.InvalidAttachment;
    var buffer: [64]u8 = undefined;
    const proc_path = try std.fmt.bufPrintSentinel(&buffer, "/proc/self/fd/{d}", .{fd}, 0);
    const filename = c.g_file_read_link(proc_path, null) orelse return error.InvalidAttachment;
    defer c.g_free(filename);
    if (!std.mem.startsWith(u8, std.mem.span(filename), "/")) return error.InvalidAttachment;
    // The mail client opens this path later. Require an existing readable file
    // referring to the passed descriptor, rather than an anonymous/deleted fd.
    const reopened = libc.open(filename, libc.O_RDONLY | libc.O_CLOEXEC | libc.O_NONBLOCK);
    if (reopened < 0) return error.InvalidAttachment;
    defer _ = libc.close(reopened);
    const current = try fileStat(reopened);
    if (current.dev_major != original.dev_major or current.dev_minor != original.dev_minor or current.ino != original.ino) return error.InvalidAttachment;
    const file = c.g_file_new_for_path(filename);
    defer c.g_object_unref(file);
    const uri = c.g_file_get_uri(file);
    defer c.g_free(uri);
    return allocator.dupeSentinel(u8, std.mem.span(uri), 0);
}

pub fn composeUri(allocator: std.mem.Allocator, options: *c.GVariant, descriptors: ?*c.GUnixFDList) ![:0]const u8 {
    var uri = Uri{ .allocator = allocator };
    defer uri.bytes.deinit(allocator);
    try uri.append("mailto:");
    const address = try option(options, "address", "s");
    defer if (address != null) c.g_variant_unref(address);
    if (address != null) try uri.recipient(text(address));
    const addresses = try option(options, "addresses", "as");
    defer if (addresses != null) c.g_variant_unref(addresses);
    if (addresses != null) try uri.recipients(addresses.?, address != null);
    try uri.append("?");
    for ([_][*:0]const u8{ "cc", "bcc" }) |key| {
        const values = try option(options, key, "as");
        defer if (values != null) c.g_variant_unref(values);
        if (values != null) {
            try uri.append(std.mem.span(key));
            try uri.append("=");
            try uri.recipients(values.?, false);
            try uri.append("&");
        }
    }
    for ([_][*:0]const u8{ "subject", "body" }) |key| {
        const value = try option(options, key, "s");
        defer if (value != null) c.g_variant_unref(value);
        try uri.append(std.mem.span(key));
        try uri.append("=");
        if (value != null) {
            const content = text(value);
            if (std.mem.eql(u8, std.mem.span(key), "subject")) {
                if (std.mem.indexOfAny(u8, content, "\r\n") != null or try std.unicode.utf8CountCodepoints(content) > 200) return error.InvalidEmailSubject;
            }
            try uri.escaped(content, false);
        }
        if (std.mem.eql(u8, std.mem.span(key), "subject")) try uri.append("&");
    }
    const attachments = try option(options, "attachment_fds", "ah");
    defer if (attachments != null) c.g_variant_unref(attachments);
    if (attachments != null) {
        for (0..c.g_variant_n_children(attachments)) |index| {
            const value = c.g_variant_get_child_value(attachments, index);
            defer c.g_variant_unref(value);
            const file_uri = try attachmentUri(allocator, descriptors, c.g_variant_get_handle(value));
            defer allocator.free(file_uri);
            try uri.append("&attachment=");
            try uri.escaped(file_uri, false);
        }
    }
    return allocator.dupeSentinel(u8, uri.bytes.items, 0);
}

fn startupId(context: ?*c.GAppLaunchContext, _: ?*c.GAppInfo, _: [*c]c.GList) callconv(.c) [*c]u8 {
    return c.g_strdup(@ptrCast(c.g_object_get_data(@ptrCast(context), "desktop-email-token")));
}
fn contextClassInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const value: *c.GAppLaunchContextClass = @ptrCast(@alignCast(klass));
    value.get_startup_notify_id = &startupId;
}
pub fn launchContext(options: *c.GVariant) !*c.GAppLaunchContext {
    const token = try option(options, "activation_token", "s");
    defer if (token != null) c.g_variant_unref(token);
    const Type = struct {
        var id: c.GType = 0;
    };
    if (Type.id == 0) Type.id = c.g_type_register_static_simple(c.g_app_launch_context_get_type(), "DesktopEmailLaunchContext", @sizeOf(c.GAppLaunchContextClass), &contextClassInit, @sizeOf(c.GAppLaunchContext), null, 0);
    const context: *c.GAppLaunchContext = @ptrCast(@alignCast(c.g_object_new(Type.id, null)));
    if (token != null) {
        c.g_object_set_data_full(@ptrCast(context), "desktop-email-token", c.g_strdup(text(token)), &c.g_free);
        c.g_app_launch_context_setenv(context, "XDG_ACTIVATION_TOKEN", text(token));
        c.g_app_launch_context_setenv(context, "DESKTOP_STARTUP_ID", text(token));
    }
    return context;
}

fn parse(value: [*:0]const u8) *c.GVariant {
    return c.g_variant_take_ref(c.g_variant_parse(null, value, null, null, null)).?;
}
test "email URI escapes recipients and Unicode headers independently" {
    const options = parse("{'address': <'a+b@example.org'>, 'addresses': <['local@host']>, 'cc': <['c&d@example.org']>, 'bcc': <['hidden@example.org']>, 'subject': <'日本語 &bcc=extra'>, 'body': <'first\\nsecond?body=other'>}");
    defer c.g_variant_unref(options);
    const uri = try composeUri(std.testing.allocator, options, null);
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings("mailto:a%2Bb@example.org,local@host?cc=c%26d@example.org&bcc=hidden@example.org&subject=%E6%97%A5%E6%9C%AC%E8%AA%9E%20%26bcc%3Dextra&body=first%0Asecond%3Fbody%3Dother", uri);
}
test "email rejects invalid recipients, subjects and typed options" {
    for ([_][*:0]const u8{ "{'address': <'Name <a@b>'>}", "{'cc': <['a@b', 'bad@-host']>}", "{'bcc': <['a@host..org']>}" }) |value| {
        const options = parse(value);
        defer c.g_variant_unref(options);
        try std.testing.expectError(error.InvalidEmailAddress, composeUri(std.testing.allocator, options, null));
    }
    for ([_][*:0]const u8{ "{'subject': <'first\\nsecond'>}", "{'subject': <'first\\rsecond'>}" }) |value| {
        const options = parse(value);
        defer c.g_variant_unref(options);
        try std.testing.expectError(error.InvalidEmailSubject, composeUri(std.testing.allocator, options, null));
    }
    const invalid = parse("{'addresses': <'a@b'>}");
    defer c.g_variant_unref(invalid);
    try std.testing.expectError(error.InvalidEmailOption, composeUri(std.testing.allocator, invalid, null));
    const missing = parse("{'attachment_fds': <[handle 0]>}");
    defer c.g_variant_unref(missing);
    try std.testing.expectError(error.MissingFileDescriptor, composeUri(std.testing.allocator, missing, null));
}
