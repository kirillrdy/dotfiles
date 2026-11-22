//! GLib declarations used only by tests that compare the desktop's Zig
//! implementations against GLib itself. Only test binaries link GLib.
pub const gboolean = c_int;
pub const GVariant = opaque {};
pub const GVariantType = opaque {};
pub extern fn g_variant_unref(value: ?*GVariant) void;
pub extern fn g_variant_take_ref(value: ?*GVariant) ?*GVariant;
pub extern fn g_variant_parse(kind: ?*const GVariantType, text: [*c]const u8, limit: [*c]const u8, end: [*c][*c]const u8, err: ?*anyopaque) ?*GVariant;
pub extern fn g_variant_print(value: ?*GVariant, annotate: gboolean) [*c]u8;
pub extern fn g_free(mem: ?*anyopaque) void;
pub extern fn g_setenv(variable: [*:0]const u8, value: [*:0]const u8, overwrite: gboolean) gboolean;
