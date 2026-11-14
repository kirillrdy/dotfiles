//! Native Wayland authentication dialogs with locked password buffers.
const std = @import("std");
pub const c = @import("desktop-gtk.zig");
pub const native = @import("desktop-askpass-view.zig");
pub const password = @import("desktop-password-entry.zig");
pub const Mode = native.Mode;
pub const host = @import("desktop-window.zig");
const wire = host.wire;
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const cast = c.__zig.cast;
pub const Dialog = struct {
    allocator: std.mem.Allocator,
    window: *host.Window,
    image: []u32 = &.{},
    offset: f64 = 0,
    response: ?bool = null,
    response_idle: c.guint = 0,
    response_context: ?*anyopaque = null,
    responded: ?*const fn (?*anyopaque, bool) void = null,
    prompt: [:0]u8,
    parent: ?[:0]u8 = null,
    entry: ?*password.Entry = null,
    confirmation: ?*password.Entry = null,
    status: ?[:0]u8 = null,
    mode: Mode,
    view: native.View,
    accepted: bool = false,
    failed: bool = false,
    enabled: bool = true,
    choice_context: ?*anyopaque = null,
    choice_selected: ?*const fn (?*anyopaque, usize) void = null,

    pub fn create(mode: Mode, prompt_text: [:0]const u8) !*Dialog {
        return createWithOptions(mode, prompt_text, .{});
    }
    pub const Options = struct {
        allocator: std.mem.Allocator = a,
        title: [:0]const u8 = "SSH Authentication",
        role: [:0]const u8 = "desktop-askpass",
        parent: [:0]const u8 = "",
        accept: ?[:0]const u8 = null,
        icon: [:0]const u8 = "dialog-password",
        confirmation: bool = false,
        cancel: ?[:0]const u8 = null,
        // Choices and their labels must outlive the dialog; flags may update in place.
        choices: []const native.Choice = &.{},
        response_context: ?*anyopaque = null,
        responded: ?*const fn (?*anyopaque, bool) void = null,
    };
    pub fn createWithOptions(mode: Mode, prompt_text: [:0]const u8, options: Options) !*Dialog {
        if (options.choices.len > 3 or (options.choices.len != 0 and mode != .information)) return error.InvalidChoices;
        if (options.confirmation and mode != .password) return error.InvalidConfirmationMode;
        const alloc = options.allocator;
        const self = try alloc.create(Dialog);
        errdefer alloc.destroy(self);
        const prompt = try alloc.dupeSentinel(u8, prompt_text, 0);
        errdefer alloc.free(prompt);
        const parent = if (options.parent.len > 0) try alloc.dupeSentinel(u8, options.parent, 0) else null;
        errdefer if (parent) |value| alloc.free(value);
        var view = native.View.init(mode);
        errdefer view.deinit(alloc);
        view.confirmation = options.confirmation;
        view.cancel_label = options.cancel;
        view.choices = options.choices;
        view.title = options.title;
        view.accept_label = options.accept;
        try view.prepare(alloc, prompt, 1);
        const window = try host.Window.create(options.title, options.role, view.width, view.height, &draw, self);
        errdefer window.destroy();
        if (parent) |value| if (window.surface) |surface| {
            surface.options.parent = value;
        };
        self.* = .{ .allocator = alloc, .window = window, .prompt = prompt, .parent = parent, .response_context = options.response_context, .responded = options.responded, .mode = mode, .view = view };
        window.closed = &closed;
        window.surface.?.close = &closeRequested;
        window.surface.?.input = .{ .button = &button, .motion = &motion, .leave = &leave, .scroll = &scroll, .symbol = &key, .text = &commit, .commit = &commit, .preedit = &preedit, .surrounding = &surrounding, .focus = &focusChanged };
        if (mode == .password) self.entry = try password.Entry.create(&changed, self);
        errdefer if (self.entry) |entry| entry.destroy();
        if (options.confirmation) self.confirmation = try password.Entry.create(&changed, self);
        errdefer if (self.confirmation) |entry| entry.destroy();
        if (self.entry) |entry| entry.client = window.surface.?.client;
        if (self.confirmation) |entry| entry.client = window.surface.?.client;
        self.size();
        try window.show();
        self.focus(self.view.focus);
        return self;
    }
    pub fn setPrompt(self: *Dialog, value: [:0]const u8) !void {
        const prompt = try self.allocator.dupeSentinel(u8, value, 0);
        errdefer self.allocator.free(prompt);
        const scale = @max(1, self.view.scale);
        self.view.invalidate(self.allocator);
        try self.view.prepare(self.allocator, prompt, scale);
        self.allocator.free(self.prompt);
        self.prompt = prompt;
        self.size();
        changed(self);
    }
    pub fn setStatus(self: *Dialog, value: [:0]const u8, is_error: bool) !void {
        const status = try self.allocator.dupeSentinel(u8, value, 0);
        if (self.status) |old| self.allocator.free(old);
        self.status = status;
        self.view.status = status;
        self.view.status_error = is_error;
        const scale = @max(1, self.view.scale);
        self.view.invalidate(self.allocator);
        try self.view.prepare(self.allocator, self.prompt, scale);
        self.size();
        self.focus(self.view.focus);
    }
    pub fn validatePassword(self: *Dialog) !bool {
        const value = self.entry.?.buffer.value();
        const problem: ?[:0]const u8 = if (value.len == 0) "Enter a password." else if (self.confirmation != null and !std.mem.eql(u8, value, self.confirmation.?.buffer.value())) "Passwords do not match. Please try again." else null;
        if (problem) |message| {
            self.clear();
            try self.setStatus(message, true);
            self.focus(.entry);
            return false;
        }
        return true;
    }
    fn focusedEntry(self: *Dialog) ?*password.Entry {
        return switch (self.view.focus) {
            .entry => self.entry,
            .confirmation => self.confirmation,
            else => null,
        };
    }
    pub fn setEnabled(self: *Dialog, enabled: bool) void {
        self.enabled = enabled;
        self.view.enabled = enabled;
        self.view.pressed = .none;
        if (self.entry) |entry| {
            entry.revision += 1;
            entry.focus(enabled and self.view.focus == .entry);
        }
        if (self.confirmation) |entry| {
            entry.revision += 1;
            entry.focus(enabled and self.view.focus == .confirmation);
        }
        changed(self);
    }
    pub fn destroy(self: *Dialog) void {
        if (self.confirmation) |entry| entry.destroy();
        if (self.entry) |entry| entry.destroy();
        if (self.response_idle != 0) _ = c.g_source_remove(self.response_idle);
        self.window.destroy();
        self.allocator.free(self.image);
        self.view.deinit(self.allocator);
        self.allocator.free(self.prompt);
        if (self.parent) |parent| self.allocator.free(parent);
        if (self.status) |status| self.allocator.free(status);
        self.allocator.destroy(self);
    }
    fn size(self: *Dialog) void {
        if (self.window.surface) |surface| {
            const height = @min(self.view.height, @as(u32, @intCast(@max(120, surface.output.height() - 60))));
            if (surface.options.height != height) self.window.setSize(self.view.width, height);
        }
        if (self.entry) |entry| {
            const rect = self.view.entryRect();
            entry.rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
        }
        if (self.confirmation) |entry| {
            const rect = self.view.confirmationRect();
            entry.rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
        }
    }
    fn changed(ptr: ?*anyopaque) void {
        const self = cast(Dialog, ptr);
        self.window.redraw();
        self.syncInput();
    }
    fn syncInput(self: *Dialog) void {
        const surface = self.window.surface orelse return;
        for (surface.client.seats.items) |seat| if (seat.text_input) |im| if (im.surface == surface) im.update();
    }
    pub fn focus(self: *Dialog, target: native.Target) void {
        self.view.focus = target;
        if (self.entry) |entry| entry.focus(self.enabled and target == .entry);
        if (self.confirmation) |entry| entry.focus(self.enabled and target == .confirmation);
        if (self.window.surface) |surface| {
            const rect = self.view.targetRect(target);
            if (rect.y < self.offset) self.offset = rect.y;
            if (rect.y + rect.height > self.offset + @as(f64, @floatFromInt(surface.height))) self.offset = rect.y + rect.height - @as(f64, @floatFromInt(surface.height));
        }
        self.clamp();
        changed(self);
    }
    fn focusChanged(ptr: ?*anyopaque, _: *wire.Surface, focused: bool) void {
        const self = cast(Dialog, ptr);
        if (self.entry) |entry| entry.focus(focused and self.enabled and self.view.focus == .entry);
        if (self.confirmation) |entry| entry.focus(focused and self.enabled and self.view.focus == .confirmation);
        if (!focused) self.view.pressed = .none;
    }
    fn clamp(self: *Dialog) void {
        const surface = self.window.surface orelse return;
        self.offset = std.math.clamp(self.offset, 0, @as(f64, @floatFromInt(self.view.height -| surface.height)));
    }
    fn draw(ptr: ?*anyopaque, target: wire.Pixels) void {
        const self = cast(Dialog, ptr);
        self.paint(target) catch {
            self.failed = true;
            self.respond(false);
        };
    }
    fn paint(self: *Dialog, target: wire.Pixels) !void {
        const surface = self.window.surface orelse return;
        const scale = surface.output.scale;
        const width = target.width / scale;
        if (self.view.width != width) {
            self.view.width = width;
            self.view.invalidate(self.allocator);
        }
        const old_height = self.view.height;
        try self.view.prepare(self.allocator, self.prompt, scale);
        if (old_height != self.view.height) self.size();
        self.clamp();
        const height = @max(self.view.height * scale, target.height);
        const bytes = try wire.bufferSize(target.width, height);
        if (self.image.len != bytes / 4) {
            const image = try self.allocator.alloc(u32, bytes / 4);
            self.allocator.free(self.image);
            self.image = image;
        }
        const image: wire.Pixels = .{ .pixels = self.image, .width = target.width, .height = height };
        self.view.paint(image);
        if (self.entry) |entry| try entry.paint(image, scale);
        if (self.confirmation) |entry| try entry.paint(image, scale);
        const start: usize = @intFromFloat(self.offset * @as(f64, @floatFromInt(scale)));
        for (0..target.height) |row| @memcpy(target.pixels[row * target.width ..][0..target.width], self.image[(start + row) * target.width ..][0..target.width]);
    }
    pub fn pointerButton(self: *Dialog, pressed: bool, x: f64, screen_y: f64) void {
        const y = screen_y + self.offset;
        const target = self.view.hit(x, y);
        if (pressed) {
            self.view.keyboard_focus = false;
            self.view.pressed = target;
            self.view.hover = target;
            if (target != .none) self.focus(target);
            if ((target == .entry or target == .confirmation) and self.enabled) {
                const entry = self.focusedEntry().?;
                entry.dragging = true;
                entry.point(x, false);
            }
        } else {
            const previous = self.view.pressed;
            self.view.pressed = .none;
            if (self.entry) |entry| entry.dragging = false;
            if (self.confirmation) |entry| entry.dragging = false;
            changed(self);
            if (previous != .none and previous == target) self.activate(target);
            return;
        }
        changed(self);
    }
    fn button(ptr: ?*anyopaque, _: *wire.Surface, code: u32, pressed: bool, x: f64, y: f64) void {
        if (code == 0x110) cast(Dialog, ptr).pointerButton(pressed, x, y);
    }
    fn motion(ptr: ?*anyopaque, _: *wire.Surface, x: f64, y: f64) void {
        const self = cast(Dialog, ptr);
        self.view.hover = self.view.hit(x, y + self.offset);
        if (self.entry) |entry| if (entry.dragging) entry.point(x, true);
        if (self.confirmation) |entry| if (entry.dragging) entry.point(x, true);
        changed(self);
    }
    fn leave(ptr: ?*anyopaque, _: *wire.Surface) void {
        const self = cast(Dialog, ptr);
        self.view.hover = .none;
        changed(self);
    }
    fn scroll(ptr: ?*anyopaque, _: *wire.Surface, axis: u32, delta: f64) void {
        const self = cast(Dialog, ptr);
        if (axis != 0) return;
        self.offset += delta * 3;
        self.clamp();
        changed(self);
    }
    fn key(ptr: ?*anyopaque, _: *wire.Surface, symbol: u32, modifiers: u32, pressed: bool) bool {
        const self = cast(Dialog, ptr);
        if (!pressed or self.response != null) return true;
        if (self.focusedEntry()) |entry| {
            if (symbol != 0xff09 and symbol != 0xfe20 and symbol != 0xff1b and symbol != 0xff0d and symbol != 0xff8d) return if (self.enabled) entry.key(symbol, modifiers) else true;
        }
        return self.handleKey(symbol, modifiers);
    }
    fn commit(ptr: ?*anyopaque, _: *wire.Surface, value: []const u8) void {
        const self = cast(Dialog, ptr);
        if (self.enabled and self.response == null) if (self.focusedEntry()) |entry| entry.insert(value) catch {};
    }
    fn preedit(ptr: ?*anyopaque, _: *wire.Surface, value: []const u8, _: i32) void {
        const self = cast(Dialog, ptr);
        if (self.enabled and self.response == null) if (self.focusedEntry()) |entry| entry.setPreedit(value);
    }
    fn surrounding(ptr: ?*anyopaque, _: *wire.Surface) ?@import("desktop-input.zig").TextState {
        const self = cast(Dialog, ptr);
        if (!self.enabled) return null;
        const entry = self.focusedEntry() orelse return null;
        const rect = entry.location;
        return .{ .text = "", .cursor = 0, .anchor = 0, .private = true, .rect = .{ .x = rect.x, .y = rect.y - @as(i32, @intFromFloat(self.offset)), .width = rect.width, .height = rect.height } };
    }
    fn closed(ptr: ?*anyopaque) void {
        cast(Dialog, ptr).respond(false);
    }
    fn closeRequested(ptr: ?*anyopaque) void {
        cast(Dialog, ptr).respond(false);
    }
    pub fn handleKey(self: *Dialog, symbol: u32, modifiers: c.GdkModifierType) bool {
        self.view.keyboard_focus = true;
        switch (symbol) {
            0xff1b => {
                self.respond(false);
                return true;
            },
            0xff09, 0xfe20 => {
                self.view.stepFocus(symbol == 0xfe20 or modifiers & c.GDK_SHIFT_MASK != 0);
                self.focus(self.view.focus);
            },
            0xff0d, 0xff8d => {
                self.activate(if (self.view.focus == .entry or self.view.focus == .confirmation) .accept else self.view.focus);
                return true;
            },
            else => {
                if (self.mode == .confirm and (symbol == 's' or symbol == 'S') and modifiers & 8 != 0) {
                    self.respond(true);
                    return true;
                }
                if (self.focusedEntry()) |entry| {
                    if (!self.enabled) return true;
                    if (!entry.key(symbol, modifiers)) {
                        const codepoint = @import("desktop-keyboard.zig").unicode(symbol);
                        if (modifiers & (c.GDK_CONTROL_MASK | c.GDK_MOD1_MASK) != 0 or codepoint < 32 or codepoint == 127) return false;
                        var bytes: [4]u8 = @splat(0);
                        defer std.crypto.secureZero(u8, &bytes);
                        const len = std.unicode.utf8Encode(@intCast(codepoint), &bytes) catch return false;
                        entry.insert(bytes[0..len]) catch {};
                    }
                } else if (symbol == 0x20) {
                    self.activate(self.view.focus);
                    return true;
                } else if (symbol == 0xff51 or symbol == 0xff53 or (self.view.choices.len != 0 and (symbol == 0xff52 or symbol == 0xff54))) {
                    self.view.stepFocus(symbol == 0xff51 or symbol == 0xff52);
                    self.focus(self.view.focus);
                } else return false;
            },
        }
        changed(self);
        return true;
    }
    pub fn activate(self: *Dialog, target: native.Target) void {
        for (native.choice_targets, 0..) |choice, i| if (target == choice) {
            if (self.view.choiceEnabled(target)) if (self.choice_selected) |callback| callback(self.choice_context, i);
            return;
        };
        if (target == .accept or target == .cancel) self.respond(target == .accept);
    }
    pub fn respond(self: *Dialog, accepted: bool) void {
        if (accepted and !self.enabled) return;
        if (!accepted) self.clear();
        if (self.response != null and accepted) return;
        self.response = accepted;
        if (self.response_idle != 0) return;
        self.response_idle = c.g_idle_add(&deliverResponse, self);
    }
    fn deliverResponse(ptr: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Dialog, ptr);
        self.response_idle = 0;
        self.accepted = self.response.? and !self.failed;
        self.response = null;
        if (self.responded) |callback| {
            if (self.mode == .confirm) self.window.hide();
            callback(self.response_context, self.accepted);
        }
        return 0;
    }
    pub fn clear(self: *Dialog) void {
        if (self.entry) |entry| entry.clear();
        if (self.confirmation) |entry| entry.clear();
    }
    fn cancel(data: c.gpointer) callconv(.c) c.gboolean {
        cast(Dialog, data).respond(false);
        return 1;
    }
    pub fn run(self: *Dialog) void {
        if (self.failed) {
            self.accepted = false;
            return;
        }
        const term = c.g_unix_signal_add(c.SIGTERM, &cancel, self);
        defer _ = c.g_source_remove(term);
        const interrupt = c.g_unix_signal_add(c.SIGINT, &cancel, self);
        defer _ = c.g_source_remove(interrupt);
        self.accepted = false;
        self.window.show() catch {
            self.failed = true;
            return;
        };
        // Preserve asynchronous response hooks; synchronous callers use a local loop.
        const previous_callback = self.responded;
        const previous_context = self.response_context;
        var done = false;
        self.responded = &runCompleted;
        self.response_context = &done;
        defer {
            self.responded = previous_callback;
            self.response_context = previous_context;
        }
        while (!done) _ = c.g_main_context_iteration(null, 1);
    }
    fn runCompleted(ptr: ?*anyopaque, _: bool) void {
        cast(bool, ptr).* = true;
    }
    pub fn writeAnswer(self: *Dialog, io: std.Io, output: std.Io.File) !u8 {
        defer self.clear();
        if (!self.accepted) return 1;
        switch (self.mode) {
            .password => {
                try output.writeStreamingAll(io, self.entry.?.buffer.value());
                try output.writeStreamingAll(io, "\n");
            },
            .confirm => try output.writeStreamingAll(io, "yes\n"),
            .information => {},
        }
        return 0;
    }
};
