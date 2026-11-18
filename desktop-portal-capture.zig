//! Native capture requests on the broker's GLib context.
const native = @import("desktop-surface.zig");
const form = @import("desktop-form.zig");
const fonts = @import("desktop-text.zig");
const raster = @import("desktop-raster.zig");
const std = @import("std");
const c = @import("desktop-gtk.zig");
const libc = @import("desktop-libc.zig");
const sc = @import("desktop-screenshot.zig");
const protocols = sc.protocols;
pub const Image = @import("desktop-image.zig").Image;
const cast = c.__zig.cast;
pub const Completion = *const fn (?*anyopaque, u32, ?*c.GVariant) void;

/// A private Wayland connection keeps capture traffic off GTK's event queue.
pub const Capture = struct {
    allocator: std.mem.Allocator,
    client: sc.WaylandClient,
    frame: ?sc.FrameCapture = null,
    source: c.guint = 0,
    timeout: c.guint = 0,
    // A successful callback owns the image and frees it with this allocator.
    callback: *const fn (?*anyopaque, ?Image) void,
    data: ?*anyopaque,

    pub fn create(allocator: std.mem.Allocator, name: []const u8, cursor: bool, callback: *const fn (?*anyopaque, ?Image) void, data: ?*anyopaque) !*Capture {
        const self = try allocator.create(Capture);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .client = undefined, .callback = callback, .data = data };
        try self.client.init(allocator);
        errdefer self.client.deinit();
        try self.next(name, cursor);
        return self;
    }
    pub fn next(self: *Capture, name: []const u8, cursor: bool) !void {
        self.clearFrame();
        const mgr = self.client.screencopy_mgr orelse return error.NoScreencopy;
        var output: ?*sc.Output = null;
        for (self.client.outputs.items) |*item| if (item.available and std.mem.eql(u8, std.mem.sliceTo(&item.name, 0), name)) {
            output = item;
            break;
        };
        const target = output orelse return error.OutputUnavailable;
        self.frame = .{
            .shm = self.client.shm orelse return error.NoShm,
            .frame = protocols.zwlr_screencopy_manager_v1_capture_output(mgr, @intFromBool(cursor), target.wl_out) orelse return error.CaptureFailed,
        };
        _ = protocols.zwlr_screencopy_frame_v1_add_listener(self.frame.?.frame, &sc.FrameCapture.listener, &self.frame.?);
        _ = c.wl_display_flush(self.client.display);
        self.source = c.g_unix_fd_add(c.wl_display_get_fd(self.client.display), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &dispatch, self);
        self.timeout = c.g_timeout_add_seconds(10, &expired, self);
    }
    fn clearFrame(self: *Capture) void {
        if (self.frame) |frame| {
            protocols.zwlr_screencopy_frame_v1_destroy(frame.frame);
            if (frame.buffer) |buffer| c.wl_buffer_destroy(buffer);
            if (frame.memory) |memory| _ = libc.munmap(memory, frame.length);
        }
        self.frame = null;
    }
    pub fn destroy(self: *Capture) void {
        if (self.source != 0) _ = c.g_source_remove(self.source);
        if (self.timeout != 0) _ = c.g_source_remove(self.timeout);
        self.clearFrame();
        self.client.deinit();
        self.allocator.destroy(self);
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Capture, data);
        self.timeout = 0;
        if (self.source != 0) _ = c.g_source_remove(self.source);
        self.source = 0;
        self.callback(self.data, null);
        return 0;
    }
    fn dispatch(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Capture, data);
        const ok = condition & (c.G_IO_ERR | c.G_IO_HUP) == 0 and c.__zig.dispatchWayland(self.client.display);
        if (ok) _ = c.wl_display_flush(self.client.display);
        const frame = &self.frame.?;
        if (ok and !frame.done and !frame.failed) return 1;
        self.source = 0;
        if (self.timeout != 0) _ = c.g_source_remove(self.timeout);
        self.timeout = 0;
        const result = if (ok and frame.done and !frame.failed) image(self.allocator, frame) catch null else null;
        // Ownership passes to the callback, which may destroy this capture.
        self.callback(self.data, result);
        return 0;
    }
};

/// Copy XRGB/ARGB capture pixels into an owned, top-down Zig image.
pub fn image(allocator: std.mem.Allocator, frame: *const sc.FrameCapture) !Image {
    if (frame.memory == null) return error.InvalidFrame;
    if (frame.format != c.WL_SHM_FORMAT_XRGB8888 and frame.format != c.WL_SHM_FORMAT_ARGB8888) return error.UnsupportedFormat;
    return Image.copy(allocator, .{
        .pixels = frame.memory.?[0..frame.length],
        .width = frame.width,
        .height = frame.height,
        .stride = frame.stride,
        .y_invert = frame.y_invert,
    });
}

pub const Picked = struct { name: [:0]const u8, width: i32, height: i32 };
/// Consent and output selection are shared by screenshots and screencasts.
pub const Picker = struct {
    allocator: std.mem.Allocator,
    ui: *form.Form,
    parent: [:0]u8,
    output: usize,
    area: ?usize = null,
    cancel: usize,
    share: usize,
    responded: bool = false,
    callback: *const fn (?*anyopaque, ?Picked, bool) void,
    data: ?*anyopaque,

    pub fn create(allocator: std.mem.Allocator, app: [:0]const u8, parent: [:0]const u8, title: [:0]const u8, interactive: bool, callback: *const fn (?*anyopaque, ?Picked, bool) void, data: ?*anyopaque) !*Picker {
        // Check capture support before displaying a consent window. This probe
        // is synchronous; the form's native connection tracks live outputs.
        var probe: sc.WaylandClient = undefined;
        try probe.init(allocator);
        defer probe.deinit();
        if (probe.screencopy_mgr == null) return error.CaptureUnavailable;
        const self = try allocator.create(Picker);
        errdefer allocator.destroy(self);
        const owned_parent = try allocator.dupeSentinel(u8, parent, 0);
        errdefer allocator.free(owned_parent);
        const ui = try form.Form.create(title, self, &action, &changed);
        errdefer ui.deinit();
        _ = try ui.add(.label, app, "", false);
        const output = try ui.add(.choice, "Screen", "", false);
        var choices: std.ArrayList(form.Option) = .empty;
        defer choices.deinit(allocator);
        const surface = ui.window.surface orelse return error.DisplayUnavailable;
        for (surface.client.outputs.items) |item| {
            if (item.width() <= 0 or item.height() <= 0) continue;
            const name = std.mem.sliceTo(&item.label, 0);
            if (name.len != 0) try choices.append(allocator, .{ .id = name, .label = name });
        }
        if (choices.items.len == 0) return error.CaptureUnavailable;
        try ui.setOptions(output, choices.items, true);
        const area = if (interactive) try ui.add(.toggle, "Select an area", "", false) else null;
        const cancel = try ui.add(.button, "Cancel", "", false);
        const share = try ui.add(.button, "Share", "", false);
        ui.pair(cancel, share);
        self.* = .{ .allocator = allocator, .ui = ui, .parent = owned_parent, .output = output, .area = area, .cancel = cancel, .share = share, .callback = callback, .data = data };
        surface.options.parent = owned_parent;
        ui.close_callback = &closed;
        ui.shortcut = &shortcut;
        ui.focus = cancel; // Enter never grants consent by default.
        ui.window.setSize(560, ui.height);
        try ui.window.show();
        return self;
    }
    pub fn destroy(self: *Picker) void {
        self.ui.close_callback = null;
        self.ui.deinit();
        self.allocator.free(self.parent);
        self.allocator.destroy(self);
    }
    fn changed(_: ?*anyopaque, _: usize) void {}
    fn closed(data: ?*anyopaque) void {
        cast(Picker, data).respond(false);
    }
    fn action(data: ?*anyopaque, id: usize) void {
        const self = cast(Picker, data);
        self.respond(id == self.share);
    }
    fn shortcut(data: ?*anyopaque, symbol: u32, modifiers: u32) bool {
        if (modifiers & c.GDK_MOD1_MASK == 0) return false;
        const self = cast(Picker, data);
        switch (symbol) {
            's', 'S' => self.ui.activate(self.share),
            'a', 'A' => if (self.area) |id| self.ui.activate(id),
            'o', 'O' => {
                self.ui.focus = self.output;
                self.ui.redraw();
            },
            else => return false,
        }
        return true;
    }
    fn respond(self: *Picker, accepted: bool) void {
        if (self.responded) return;
        self.responded = true;
        self.ui.window.hide();
        if (accepted) if (self.ui.get(self.output).selectedId()) |name| {
            if (self.ui.window.surface) |surface| for (surface.client.outputs.items) |output| {
                if (!std.mem.eql(u8, std.mem.sliceTo(&output.label, 0), name)) continue;
                if (output.width() <= 0 or output.height() <= 0) break;
                const area = if (self.area) |id| self.ui.get(id).checked else false;
                self.callback(self.data, .{ .name = name, .width = output.width(), .height = output.height() }, area);
                return; // The callback may destroy both the picker and form.
            };
        };
        self.callback(self.data, null, false);
    }
};

pub const Operation = struct {
    allocator: std.mem.Allocator,
    picker: ?*Picker = null,
    capture: ?*Capture = null,
    overlay_client: ?*native.Client = null,
    overlay: ?*native.Surface = null,
    renderer: fonts.Renderer = .{},
    hint: ?fonts.Mask = null,
    hint_scale: u32 = 0,
    selection_done: bool = false,
    timer: c.guint = 0,
    name: ?[:0]u8 = null,
    point: bool,
    region: ?sc.Rect = null,
    width: i32 = 0,
    height: i32 = 0,
    start_x: f64 = 0,
    start_y: f64 = 0,
    current_x: f64 = 0,
    current_y: f64 = 0,
    dragging: bool = false,
    callback: Completion,
    data: ?*anyopaque,

    pub fn create(allocator: std.mem.Allocator, app: [:0]const u8, parent: [:0]const u8, method: []const u8, options: *c.GVariant, callback: Completion, data: ?*anyopaque) !*Operation {
        var interactive = false;
        for ([_][*:0]const u8{ "interactive", "modal" }) |option_key| {
            const value = c.g_variant_lookup_value(options, option_key, null);
            defer if (value != null) c.g_variant_unref(value);
            if (value != null and !std.mem.eql(u8, std.mem.span(c.g_variant_get_type_string(value)), "b")) return error.InvalidScreenshotOptions;
        }
        const hint = c.g_variant_lookup_value(options, "interactive", null);
        if (hint != null) {
            interactive = c.g_variant_get_boolean(hint) != 0;
            c.g_variant_unref(hint);
        }
        const self = try allocator.create(Operation);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .point = std.mem.eql(u8, method, "PickColor"), .callback = callback, .data = data };
        self.picker = try Picker.create(allocator, app, parent, if (self.point) "Pick a color" else "Share a screenshot", interactive and !self.point, &picked, self);
        return self;
    }
    pub fn destroy(self: *Operation) void {
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        if (self.capture) |capture| capture.destroy();
        if (self.picker) |picker| picker.destroy();
        if (self.overlay_client) |client| client.destroy();
        if (self.hint) |mask| mask.deinit(self.allocator);
        self.renderer.deinit();
        if (self.name) |name| self.allocator.free(name);
        self.allocator.destroy(self);
    }
    fn picked(data: ?*anyopaque, output: ?Picked, area: bool) void {
        const self = cast(Operation, data);
        const chosen = output orelse return self.finish(1, null);
        self.name = self.allocator.dupeSentinel(u8, chosen.name, 0) catch return self.finish(2, null);
        self.width = chosen.width;
        self.height = chosen.height;
        if (area or self.point) {
            self.overlay_client = native.Client.createInteractive(.{ .added = &outputAdded, .removed = &outputRemoved }, self) catch return self.finish(2, null);
            self.overlay_client.?.start() catch return self.finish(2, null);
            if (self.overlay == null) return self.finish(2, null);
            // Completion runs outside Wayland dispatch: callbacks can destroy
            // the operation, its input seats, and the private connection.
            self.timer = c.g_timeout_add(16, &selectionFinished, self);
        } else self.schedule();
    }
    fn outputAdded(data: ?*anyopaque, output: *native.Output) void {
        const self = cast(Operation, data);
        if (self.selection_done or self.overlay != null or !std.mem.eql(u8, std.mem.sliceTo(&output.label, 0), self.name.?)) return;
        const surface = native.Surface.createPixels(output, .{
            .namespace = "desktop-portal-selection",
            .layer = 3,
            .anchors = native.top | native.bottom | native.left | native.right,
            .interactive = true,
            .keyboard = .exclusive,
        }, &draw, self) catch return;
        self.overlay = surface;
        surface.input = .{ .motion = &motion, .button = &button, .key = &key };
        surface.close = &overlayClosed;
        surface.show() catch {
            self.overlay = null;
            surface.destroy();
        };
    }
    fn outputRemoved(data: ?*anyopaque, output: *native.Output) void {
        const self = cast(Operation, data);
        if (self.overlay) |surface| if (surface.output == output) {
            self.overlay = null; // Client destroys the surface after this callback.
            self.region = null;
            self.selection_done = true;
        };
    }
    fn overlayClosed(data: ?*anyopaque) void {
        const self = cast(Operation, data);
        self.region = null;
        self.selection_done = true;
    }
    fn draw(data: ?*anyopaque, target: native.Pixels) void {
        const self = cast(Operation, data);
        const surface = self.overlay orelse return;
        const scale = surface.buffer_scale;
        sc.paintSelectionRegion(target, scale, if (self.dragging and !self.point) self.rectangle(surface.width, surface.height) else null);
        if (self.hint == null or self.hint_scale != scale) {
            const mask = self.renderer.render(self.allocator, "Adwaita Sans Bold", 16 * scale, if (self.point) "Click to pick a color. Esc to cancel." else "Drag to select an area. Esc to cancel.") catch return;
            if (self.hint) |old| old.deinit(self.allocator);
            self.hint = mask;
            self.hint_scale = scale;
        }
        self.hint.?.paint(.{ .target = target, .scale = 1 }, @floatFromInt(32 * scale), @floatFromInt(40 * scale), raster.hex(0xffffff));
    }
    fn rectangle(self: *const Operation, width: u32, height: u32) sc.Rect {
        return sc.Rect.between(self.start_x, self.start_y, self.current_x, self.current_y, width, height);
    }
    fn motion(data: ?*anyopaque, surface: *native.Surface, x: f64, y: f64) void {
        const self = cast(Operation, data);
        if (self.selection_done or !self.dragging) return;
        self.current_x = x;
        self.current_y = y;
        surface.redraw();
    }
    fn button(data: ?*anyopaque, surface: *native.Surface, code: u32, pressed: bool, x: f64, y: f64) void {
        const self = cast(Operation, data);
        if (self.selection_done) return;
        if (code != 272) {
            if (pressed) overlayClosed(self);
            return;
        }
        if (pressed) {
            self.start_x = x;
            self.start_y = y;
            self.current_x = x;
            self.current_y = y;
            self.dragging = true;
            surface.redraw();
        } else if (self.dragging) {
            self.current_x = x;
            self.current_y = y;
            self.dragging = false;
            self.width = @intCast(surface.width);
            self.height = @intCast(surface.height);
            const rect = if (self.point) sc.Rect{
                .x = @intFromFloat(std.math.clamp(x, 0, @as(f64, @floatFromInt(surface.width -| 1)))),
                .y = @intFromFloat(std.math.clamp(y, 0, @as(f64, @floatFromInt(surface.height -| 1)))),
                .w = 1,
                .h = 1,
            } else self.rectangle(surface.width, surface.height);
            self.region = if (rect.w > 0 and rect.h > 0) rect else null;
            self.selection_done = true;
        }
    }
    fn key(data: ?*anyopaque, _: *native.Surface, code: u32, pressed: bool) void {
        if (code == 1 and pressed) overlayClosed(data);
    }
    fn selectionFinished(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Operation, data);
        const client = self.overlay_client.?;
        const mapped = if (self.overlay) |surface| surface.role != null else false;
        if (client.failed or !client.hasInput() or !mapped) {
            self.region = null;
            self.selection_done = true;
        }
        if (!self.selection_done) return 1;
        self.timer = 0;
        if (self.overlay) |surface| surface.hide();
        if (self.region == null) self.finish(1, null) else self.schedule();
        return 0;
    }
    fn schedule(self: *Operation) void {
        self.timer = c.g_timeout_add(150, &startCapture, self);
    }
    fn startCapture(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Operation, data);
        self.timer = 0;
        self.capture = Capture.create(self.allocator, self.name.?, false, &captured, self) catch {
            self.finish(2, null);
            return 0;
        };
        return 0;
    }
    fn captured(data: ?*anyopaque, source: ?Image) void {
        const self = cast(Operation, data);
        const surface = source orelse return self.finish(2, null);
        const allocator = self.allocator;
        defer surface.deinit(allocator);
        const width: i32 = @intCast(surface.width);
        const height: i32 = @intCast(surface.height);
        var x: i32 = 0;
        var y: i32 = 0;
        var w = width;
        var h = height;
        if (self.region) |region| {
            // Native surface coordinates are logical; screencopy pixels are physical.
            x = @intCast(@divFloor(@as(i64, region.x) * width, self.width));
            y = @intCast(@divFloor(@as(i64, region.y) * height, self.height));
            w = @intCast(@divFloor(@as(i64, region.w) * width, self.width));
            h = @intCast(@divFloor(@as(i64, region.h) * height, self.height));
            x = std.math.clamp(x, 0, width - 1);
            y = std.math.clamp(y, 0, height - 1);
            w = std.math.clamp(w, 1, width - x);
            h = std.math.clamp(h, 1, height - y);
        }
        const results = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
        defer c.g_variant_builder_unref(results);
        if (self.point) {
            const pixels = surface.pixels;
            const stride = surface.stride;
            const pixel = std.mem.readInt(u32, pixels[@as(usize, @intCast(y)) * stride + @as(usize, @intCast(x)) * 4 ..][0..4], @import("builtin").cpu.arch.endian());
            c.g_variant_builder_add(results, "{sv}", @as([*:0]const u8, "color"), c.g_variant_new("(ddd)", @as(f64, @floatFromInt((pixel >> 16) & 255)) / 255, @as(f64, @floatFromInt((pixel >> 8) & 255)) / 255, @as(f64, @floatFromInt(pixel & 255)) / 255));
        } else {
            const stride = surface.stride;
            const pixels = surface.pixels;
            const offset = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(x)) * 4;
            const length = @as(usize, @intCast(h - 1)) * stride + @as(usize, @intCast(w)) * 4;
            const encoded = sc.png.encode(allocator, .{
                .pixels = pixels[offset..][0..length],
                .width = @intCast(w),
                .height = @intCast(h),
                .stride = stride,
            }) catch return self.finish(2, null);
            defer allocator.free(encoded);
            const filename = std.fmt.allocPrintSentinel(allocator, "{s}/desktop-screenshot-XXXXXX", .{c.g_get_user_runtime_dir()}, 0) catch return self.finish(2, null);
            defer allocator.free(filename);
            const fd = c.g_mkstemp(filename);
            if (fd < 0) return self.finish(2, null);
            defer _ = libc.close(fd);
            sc.writeAll(fd, encoded) catch {
                _ = libc.unlink(filename);
                return self.finish(2, null);
            };
            const uri = c.g_filename_to_uri(filename, null, null);
            if (uri == null) {
                _ = libc.unlink(filename);
                return self.finish(2, null);
            }
            defer c.g_free(uri);
            c.g_variant_builder_add(results, "{sv}", @as([*:0]const u8, "uri"), c.g_variant_new("s", uri));
        }
        self.finish(0, c.g_variant_builder_end(results));
    }
    fn finish(self: *Operation, code: u32, results: ?*c.GVariant) void {
        self.callback(self.data, code, results orelse c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "{sv}")), null, 0));
    }
};

test "capture images normalize inverted rows and preserve padding and RGB channels" {
    var pixels = [_]u32{ 0x00ff0000, 0x0000ff00, 0xdeadbeef, 0x000000ff, 0x00ffffff, 0xdeadbeef };
    const frame = sc.FrameCapture{
        .shm = undefined,
        .frame = undefined,
        .format = c.WL_SHM_FORMAT_XRGB8888,
        .width = 2,
        .height = 2,
        .stride = 12,
        .memory = @ptrCast(&pixels),
        .length = @sizeOf(@TypeOf(pixels)),
        .y_invert = true,
    };
    const surface = try image(std.testing.allocator, &frame);
    defer surface.deinit(std.testing.allocator);
    const bytes = surface.pixels;
    const stride = surface.stride;
    const endian = @import("builtin").cpu.arch.endian();
    try std.testing.expectEqual(@as(u32, 0xff), std.mem.readInt(u32, bytes[0..4], endian) & 0xffffff);
    try std.testing.expectEqual(@as(u32, 0xffffff), std.mem.readInt(u32, bytes[4..8], endian) & 0xffffff);
    try std.testing.expectEqual(@as(u32, 0xff0000), std.mem.readInt(u32, bytes[stride..][0..4], endian) & 0xffffff);
    var invalid = frame;
    invalid.length -= 1;
    try std.testing.expectError(error.InvalidFrame, image(std.testing.allocator, &invalid));
    invalid = frame;
    invalid.stride = 4;
    try std.testing.expectError(error.InvalidFrame, image(std.testing.allocator, &invalid));
    invalid = frame;
    invalid.format = 0xdeadbeef;
    try std.testing.expectError(error.UnsupportedFormat, image(std.testing.allocator, &invalid));
}

test "portal selection clips reverse drags and ignores input queued after cancellation" {
    const Callback = struct {
        fn complete(_: ?*anyopaque, _: u32, _: ?*c.GVariant) void {}
    };
    var operation: Operation = .{
        .allocator = std.testing.allocator,
        .point = false,
        .callback = &Callback.complete,
        .data = null,
        .start_x = 400,
        .start_y = 300,
        .current_x = 100,
        .current_y = 100,
        .dragging = true,
    };
    try std.testing.expectEqual(sc.Rect{ .x = 100, .y = 100, .w = 300, .h = 200 }, operation.rectangle(864, 540));
    operation.start_x = -20;
    operation.start_y = -10;
    operation.current_x = 1000;
    operation.current_y = 700;
    try std.testing.expectEqual(sc.Rect{ .x = 0, .y = 0, .w = 864, .h = 540 }, operation.rectangle(864, 540));
    var surface: native.Surface = undefined;
    Operation.key(&operation, &surface, 1, true);
    Operation.motion(&operation, &surface, 200, 150);
    Operation.button(&operation, &surface, 272, false, 200, 150);
    try std.testing.expect(operation.selection_done);
    try std.testing.expect(operation.region == null);
}
