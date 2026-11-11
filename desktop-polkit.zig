//! PolicyKit prompts rendered with native pixels and a locked password buffer.
const std = @import("std");
pub const c = @import("desktop-gtk.zig");
const auth = @import("desktop-auth-dialog.zig");
const a = std.heap.page_allocator;

pub const Dialog = struct {
    native: *auth.Dialog,
    window: *auth.host.Window,
    action: ?[:0]const u8,
    message: [:0]const u8,
    user: ?[:0]const u8,
    prompt: ?[:0]u8 = null,
    status: ?[:0]u8 = null,

    pub fn create(action: ?[:0]const u8, message: [:0]const u8, user: ?[:0]const u8, icon: ?[:0]const u8) !Dialog {
        const native = try auth.Dialog.createWithOptions(.password, message, .{
            .title = "Authentication Required",
            .role = "desktop-polkit",
            .accept = "Authenticate",
            .icon = icon orelse "dialog-password",
        });
        errdefer native.destroy();
        var self: Dialog = .{ .native = native, .window = native.window, .action = action, .message = message, .user = user };
        try self.refresh();
        self.setEnabled(false);
        return self;
    }
    fn refresh(self: *Dialog) !void {
        const value = try std.fmt.allocPrintSentinel(a, "{s}\n\nAction: {s}\n{s} ({s})", .{
            self.message, self.action orelse "", self.prompt orelse "Password:", self.user orelse "",
        }, 0);
        defer a.free(value);
        self.native.view.status = self.status;
        try self.native.setPrompt(value);
    }
    pub fn setPrompt(self: *Dialog, prompt: [:0]const u8, echo: bool) !void {
        const value = try a.dupeSentinel(u8, prompt, 0);
        const old = self.prompt;
        self.prompt = value;
        defer if (old) |v| a.free(v);
        self.clear();
        self.native.entry.?.echo = echo;
        try self.refresh();
        self.setEnabled(true);
        self.native.view.focus = .entry;
        self.native.entry.?.focus(true);
        self.native.focus(.entry);
    }
    pub fn setStatus(self: *Dialog, message: []const u8) !void {
        const value = try a.dupeSentinel(u8, message, 0);
        const old = self.status;
        self.status = value;
        self.native.view.status_error = false;
        defer if (old) |v| a.free(v);
        try self.refresh();
    }
    pub fn setError(self: *Dialog, message: []const u8) !void {
        try self.setStatus(message);
        self.native.view.status_error = true;
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
        if (self.prompt) |v| a.free(v);
        if (self.status) |v| a.free(v);
    }
};

pub const Service = @import("desktop-polkit-agent.zig").Service;
