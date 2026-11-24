//! PolicyKit prompts rendered with native pixels and a locked password buffer.
const std = @import("std");
const auth = @import("desktop-auth-dialog.zig");

pub const Dialog = struct {
    allocator: std.mem.Allocator,
    native: *auth.Dialog,
    window: *auth.host.Window,
    action: ?[:0]const u8,
    message: [:0]const u8,
    user: ?[:0]const u8,
    prompt: ?[:0]u8 = null,

    pub fn create(a: std.mem.Allocator, action: ?[:0]const u8, message: [:0]const u8, user: ?[:0]const u8) !Dialog {
        const native = try auth.Dialog.createWithOptions(a, .password, message, .{
            .title = "Authentication Required",
            .role = "desktop-polkit",
            .accept = "Authenticate",
        });
        errdefer native.destroy();
        var self: Dialog = .{ .allocator = a, .native = native, .window = native.window, .action = action, .message = message, .user = user };
        try self.refresh();
        self.setEnabled(false);
        return self;
    }
    fn refresh(self: *Dialog) !void {
        const value = try std.fmt.allocPrintSentinel(self.allocator, "{s}\n\nAction: {s}\n{s} ({s})", .{
            self.message, self.action orelse "", self.prompt orelse "Password:", self.user orelse "",
        }, 0);
        defer self.allocator.free(value);
        try self.native.setPrompt(value);
    }
    pub fn setPrompt(self: *Dialog, prompt: [:0]const u8, echo: bool) !void {
        const value = try self.allocator.dupeSentinel(u8, prompt, 0);
        const old = self.prompt;
        self.prompt = value;
        defer if (old) |v| self.allocator.free(v);
        self.clear();
        self.native.entry.?.echo = echo;
        try self.refresh();
        self.setEnabled(true);
        self.native.view.focus = .entry;
        self.native.entry.?.focus(true);
        self.native.focus(.entry);
    }
    pub fn setStatus(self: *Dialog, message: []const u8) !void {
        try self.native.setStatus(message, false);
    }
    pub fn setError(self: *Dialog, message: []const u8) !void {
        try self.native.setStatus(message, true);
    }
    pub fn setEnabled(self: *Dialog, enabled: bool) void {
        self.native.setEnabled(enabled);
    }
    pub fn answer(self: *Dialog) []const u8 {
        return self.native.entry.?.buffer.value();
    }
    pub fn clear(self: *Dialog) void {
        self.native.clear();
    }
    pub fn destroy(self: *Dialog) void {
        self.native.destroy();
        if (self.prompt) |v| self.allocator.free(v);
    }
};

pub const Service = @import("desktop-polkit-agent.zig").Service;
