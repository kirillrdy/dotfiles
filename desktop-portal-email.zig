//! Compose mail through the configured mailto handler, without a portal backend.
const std = @import("std");
const libc = @import("desktop-libc.zig");
const files = @import("desktop-paths.zig");

const portal_options = @import("desktop-portal-options.zig");
const Options = portal_options.Options(error.InvalidEmailOption);
const option = Options.get;
const dbus = @import("dbus");
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
    fn recipients(self: *Uri, values: dbus.Value, comma: bool) !void {
        for (values.array.items, 0..) |value, index| {
            if (comma or index > 0) try self.append(",");
            try self.recipient(value.string);
        }
    }
};

fn fileStat(fd: c_int) !std.os.linux.Statx {
    var result: std.os.linux.Statx = undefined;
    if (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .INO = true }, &result) != 0 or !result.mask.TYPE or !result.mask.INO) return error.InvalidAttachment;
    return result;
}

/// `handle` is a descriptor number that must be one of the message's `descriptors`.
fn attachmentUri(allocator: std.mem.Allocator, descriptors: []const i32, handle: c_int) ![:0]const u8 {
    if (descriptors.len == 0) return error.MissingFileDescriptor;
    if (std.mem.indexOfScalar(i32, descriptors, handle) == null) return error.InvalidFileDescriptor;
    const fd = std.c.fcntl(handle, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (fd < 0) return error.InvalidFileDescriptor;
    defer _ = libc.close(fd);
    const original = try fileStat(fd);
    if (original.mode & std.c.S.IFMT != std.c.S.IFREG) return error.InvalidAttachment;
    var buffer: [64]u8 = undefined;
    const proc_path = try std.fmt.bufPrintSentinel(&buffer, "/proc/self/fd/{d}", .{fd}, 0);
    const filename = files.readLink(allocator, proc_path) catch return error.InvalidAttachment;
    defer allocator.free(filename);
    if (!std.mem.startsWith(u8, filename, "/")) return error.InvalidAttachment;
    // The mail client opens this path later. Require an existing readable file
    // referring to the passed descriptor, rather than an anonymous/deleted fd.
    const reopened = libc.open(filename, libc.O_RDONLY | libc.O_CLOEXEC | libc.O_NONBLOCK);
    if (reopened < 0) return error.InvalidAttachment;
    defer _ = libc.close(reopened);
    const current = try fileStat(reopened);
    if (current.dev_major != original.dev_major or current.dev_minor != original.dev_minor or current.ino != original.ino) return error.InvalidAttachment;
    return files.fileUri(allocator, filename);
}

pub fn composeUri(allocator: std.mem.Allocator, options: portal_options.Dict, descriptors: []const i32) ![:0]const u8 {
    var uri = Uri{ .allocator = allocator };
    defer uri.bytes.deinit(allocator);
    try uri.append("mailto:");
    const address = try option(options, "address", "s");
    if (address) |value| try uri.recipient(value.string);
    const addresses = try option(options, "addresses", "as");
    if (addresses != null) try uri.recipients(addresses.?, address != null);
    try uri.append("?");
    for ([_][]const u8{ "cc", "bcc" }) |key| {
        const values = try option(options, key, "as");
        if (values != null) {
            try uri.append(key);
            try uri.append("=");
            try uri.recipients(values.?, false);
            try uri.append("&");
        }
    }
    for ([_][]const u8{ "subject", "body" }) |key| {
        const value = try option(options, key, "s");
        try uri.append(key);
        try uri.append("=");
        if (value != null) {
            const content = value.?.string;
            if (std.mem.eql(u8, key, "subject")) {
                if (std.mem.indexOfAny(u8, content, "\r\n") != null or try std.unicode.utf8CountCodepoints(content) > 200) return error.InvalidEmailSubject;
            }
            try uri.escaped(content, false);
        }
        if (std.mem.eql(u8, key, "subject")) try uri.append("&");
    }
    const attachments = try option(options, "attachment_fds", "ah");
    if (attachments) |list| {
        for (list.array.items) |value| {
            const file_uri = try attachmentUri(allocator, descriptors, value.fd);
            defer allocator.free(file_uri);
            try uri.append("&attachment=");
            try uri.escaped(file_uri, false);
        }
    }
    return allocator.dupeSentinel(u8, uri.bytes.items, 0);
}

/// The xdg-activation token the mail client should start with, if the caller gave one.
pub fn activationToken(options: portal_options.Dict) !?[]const u8 {
    return Options.string(options, "activation_token");
}

/// Options from their GVariant text form.
fn parse(a: std.mem.Allocator, value: []const u8) portal_options.Dict {
    const parsed = @import("desktop-dbus-text.zig").parse(a, "a{sv}", value) catch unreachable;
    return portal_options.fromValue(a, parsed) catch unreachable;
}
test "email URI escapes recipients and Unicode headers independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const options = parse(arena.allocator(), "{'address': <'a+b@example.org'>, 'addresses': <['local@host']>, 'cc': <['c&d@example.org']>, 'bcc': <['hidden@example.org']>, 'subject': <'日本語 &bcc=extra'>, 'body': <'first\\nsecond?body=other'>}");
    const uri = try composeUri(std.testing.allocator, options, &.{});
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings("mailto:a%2Bb@example.org,local@host?cc=c%26d@example.org&bcc=hidden@example.org&subject=%E6%97%A5%E6%9C%AC%E8%AA%9E%20%26bcc%3Dextra&body=first%0Asecond%3Fbody%3Dother", uri);
}
test "email rejects invalid recipients, subjects and typed options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{'address': <'Name <a@b>'>}", "{'cc': <['a@b', 'bad@-host']>}", "{'bcc': <['a@host..org']>}" }) |value| {
        const options = parse(a, value);
        try std.testing.expectError(error.InvalidEmailAddress, composeUri(std.testing.allocator, options, &.{}));
    }
    for ([_][]const u8{ "{'subject': <'first\\nsecond'>}", "{'subject': <'first\\rsecond'>}" }) |value| {
        const options = parse(a, value);
        try std.testing.expectError(error.InvalidEmailSubject, composeUri(std.testing.allocator, options, &.{}));
    }
    const invalid = parse(a, "{'addresses': <'a@b'>}");
    try std.testing.expectError(error.InvalidEmailOption, composeUri(std.testing.allocator, invalid, &.{}));
    const missing = parse(a, "{'attachment_fds': <[handle 0]>}");
    try std.testing.expectError(error.MissingFileDescriptor, composeUri(std.testing.allocator, missing, &.{}));
}
