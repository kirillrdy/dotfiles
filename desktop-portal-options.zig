//! Typed portal options. Successful lookups return an owned variant reference.
const std = @import("std");
const c = @import("desktop-gtk.zig");

pub fn Options(comptime invalid: anyerror) type {
    return struct {
        pub fn get(options: ?*c.GVariant, key: [*:0]const u8, signature: [:0]const u8) !?*c.GVariant {
            const value = c.g_variant_lookup_value(options, key, null) orelse return null;
            if (!std.mem.eql(u8, std.mem.span(c.g_variant_get_type_string(value)), signature)) {
                c.g_variant_unref(value);
                return invalid;
            }
            return value;
        }

        pub fn boolean(options: ?*c.GVariant, key: [*:0]const u8, fallback: bool) !bool {
            const value = try get(options, key, "b") orelse return fallback;
            defer c.g_variant_unref(value);
            return c.g_variant_get_boolean(value) != 0;
        }
    };
}

test "portal options distinguish missing values from invalid types and retain returned values" {
    const Check = Options(error.InvalidTestOption);
    const options = c.g_variant_take_ref(c.g_variant_parse(null, "{'enabled': <true>, 'disabled': <false>, 'title': <'Print'>}", null, null, null)).?;
    defer c.g_variant_unref(options);
    try std.testing.expectEqual(@as(?*c.GVariant, null), try Check.get(options, "missing", "s"));
    try std.testing.expect(try Check.boolean(options, "missing", true));
    try std.testing.expect(!try Check.boolean(options, "missing", false));
    try std.testing.expect(try Check.boolean(options, "enabled", false));
    try std.testing.expect(!try Check.boolean(options, "disabled", true));
    try std.testing.expectError(error.InvalidTestOption, Check.boolean(options, "title", false));
    try std.testing.expectError(error.InvalidEmailOption, Options(error.InvalidEmailOption).get(options, "enabled", "s"));

    const title = blk: {
        const owner = c.g_variant_take_ref(c.g_variant_parse(null, "{'title': <'Print'>}", null, null, null)).?;
        defer c.g_variant_unref(owner);
        break :blk (try Check.get(owner, "title", "s")).?;
    };
    defer c.g_variant_unref(title);
    try std.testing.expectEqualStrings("Print", std.mem.span(c.g_variant_get_string(title, null)));
}
