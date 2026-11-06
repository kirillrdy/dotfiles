//! Account information is released only after explicit consent in a native dialog.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const cast = c.__zig.cast;
const consent = @import("desktop-consent.zig");
pub const Completion = *const fn (?*anyopaque, u32, ?*c.GVariant) void;
pub const Dialog = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    host: ?*consent.Dialog = null,
    id: [:0]const u8,
    name: [:0]const u8,
    image: [:0]const u8,
    callback: Completion,
    data: ?*anyopaque,
    finished: bool = false,

    pub fn create(allocator: std.mem.Allocator, app: [:0]const u8, parent: [:0]const u8, options: *c.GVariant, callback: Completion, data: ?*anyopaque) !*Dialog {
        const reason = c.g_variant_lookup_value(options, "reason", null);
        defer if (reason != null) c.g_variant_unref(reason);
        if (reason != null and !std.mem.eql(u8, std.mem.span(c.g_variant_get_type_string(reason)), "s")) return error.InvalidAccountReason;
        const self = try allocator.create(Dialog);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .id = undefined,
            .name = undefined,
            .image = "",
            .callback = callback,
            .data = data,
        };
        errdefer self.destroy();
        const a = self.arena.allocator();
        self.id = try a.dupeSentinel(u8, std.mem.span(c.g_get_user_name()), 0);
        const real = std.mem.span(c.g_get_real_name());
        self.name = try a.dupeSentinel(u8, if (std.mem.eql(u8, real, "Unknown") or real.len == 0) self.id else real, 0);
        const face = try std.fmt.allocPrintSentinel(a, "{s}/.face", .{c.g_get_home_dir()}, 0);
        const file = c.g_file_new_for_path(face);
        defer c.g_object_unref(file);
        if (c.g_file_query_file_type(file, 0, null) == 1) {
            const uri = c.g_file_get_uri(file);
            defer c.g_free(uri);
            self.image = try a.dupeSentinel(u8, std.mem.span(uri), 0);
        }
        const prompt = try std.fmt.allocPrintSentinel(a, "{s} wants to access your account information.\n{s}\nName: {s}\nUser name: {s}\n{s}", .{ app, if (reason != null) c.g_variant_get_string(reason, null) else @as([*:0]const u8, ""), self.name, self.id, if (self.image.len > 0) "Your account picture will also be shared." else "" }, 0);
        self.host = try consent.Dialog.create(allocator, "Share account information", prompt, "Share", parent, self, &responded);
        return self;
    }
    pub fn destroy(self: *Dialog) void {
        if (self.host) |host| host.destroy();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    fn responded(data: ?*anyopaque, accepted: bool) void {
        const self = cast(Dialog, data);
        if (self.finished) return;
        self.finished = true;
        const values = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
        defer c.g_variant_builder_unref(values);
        if (accepted) {
            c.g_variant_builder_add(values, "{sv}", @as([*:0]const u8, "id"), c.g_variant_new("s", self.id.ptr));
            c.g_variant_builder_add(values, "{sv}", @as([*:0]const u8, "name"), c.g_variant_new("s", self.name.ptr));
            c.g_variant_builder_add(values, "{sv}", @as([*:0]const u8, "image"), c.g_variant_new("s", self.image.ptr));
        }
        self.callback(self.data, if (accepted) 0 else 1, c.g_variant_builder_end(values));
    }
};
