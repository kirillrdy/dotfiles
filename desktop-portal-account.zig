//! Account information is released only after explicit consent in a native dialog.
const std = @import("std");
const util = @import("desktop-util.zig");
fn cast(comptime T: type, ptr: anytype) *T { return @ptrCast(@alignCast(ptr)); }
const auth = @import("desktop-auth-dialog.zig");
const portal_options = @import("desktop-portal-options.zig");
const Options = portal_options.Options(error.InvalidAccountReason);
const dbus = @import("dbus");
pub const Completion = portal_options.Completion;
pub const Dialog = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    host: ?*auth.Dialog = null,
    id: [:0]const u8,
    name: [:0]const u8,
    image: [:0]const u8,
    callback: Completion,
    data: ?*anyopaque,
    finished: bool = false,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, app: [:0]const u8, parent: [:0]const u8, options: portal_options.Dict, callback: Completion, data: ?*anyopaque) !*Dialog {
        const reason = try Options.string(options, "reason") orelse "";
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
        const files = @import("desktop-paths.zig");
        self.id = try a.dupeSentinel(u8, files.userName(), 0);
        const real = files.realName();
        self.name = try a.dupeSentinel(u8, if (real.len == 0) self.id else real, 0);
        const face = try std.fmt.allocPrint(a, "{s}/.face", .{files.home()});
        if (files.kind(face) == .file) self.image = try files.fileUri(a, face);
        const prompt = try std.fmt.allocPrintSentinel(a, "{s} wants to access your account information.\n{s}\nName: {s}\nUser name: {s}\n{s}", .{ app, reason, self.name, self.id, if (self.image.len > 0) "Your account picture will also be shared." else "" }, 0);
        self.host = try auth.Dialog.createWithOptions(allocator, io, .confirm, prompt, .{ .title = "Share account information", .role = "desktop-consent", .accept = "Share", .cancel = "Cancel", .parent = parent, .response_context = self, .responded = &responded });
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
        const entries = [_]portal_options.Dict.Entry{
            .{ .key = "id", .value = .{ .string = self.id } },
            .{ .key = "name", .value = .{ .string = self.name } },
            .{ .key = "image", .value = .{ .string = self.image } },
        };
        self.callback(self.data, if (accepted) 0 else 1, .{ .entries = if (accepted) &entries else &.{} });
    }
};
