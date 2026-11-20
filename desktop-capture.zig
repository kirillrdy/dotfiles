//! Live, per-window captures; no screenshots of the composed desktop.
const std = @import("std");
const wl = @import("wayland-client");
const wire = @import("wayland-wire");
const helpers = @import("desktop-wayland-client.zig");
pub const c = @import("desktop-glib.zig");
const libc = @import("desktop-libc.zig");
pub const Image = @import("desktop-image.zig").Image;
const a = std.heap.page_allocator;
const cast = c.__zig.cast;
const formats = wl.wl_shm.Format;
pub const Rect = struct { x: f64 = 0, y: f64 = 0, w: f64 = 1, h: f64 = 1 };
pub const Workspace = struct { name: [128:0]u8 = @splat(0) };

pub const Window = struct {
    client: *Client,
    handle: wl.ext_foreign_toplevel_handle_v1,
    id: [*c]u8 = null,
    title: [*c]u8 = null,
    app_id: [*c]u8 = null,
    workspace: u32 = 0,
    sticky: bool = false,
    stacking: usize = 0,
    geometry: Rect = .{},
    target: Rect = .{},
    icon: ?c.__icons.Image = null,
    image: ?Image = null,
    thumbnail: ?*Thumbnail = null,
    source: ?wl.ext_image_capture_source_v1 = null,
    session: ?wl.ext_image_copy_capture_session_v1 = null,
    frame: ?wl.ext_image_copy_capture_frame_v1 = null,
    buffer: ?wl.wl_buffer = null,
    mapped: ?*anyopaque = null,
    length: usize = 0,
    buffer_width: u32 = 0,
    buffer_height: u32 = 0,
    buffer_format: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = formats.xrgb8888,
    supported: bool = false,
    constraints: bool = false,

    fn stop(self: *Window) void {
        if (self.thumbnail) |thumbnail| {
            // A worker may still be reading this completed capture. Detach its
            // owner and transfer the mapping so hide/close never unmaps it early.
            thumbnail.owner = null;
            thumbnail.owns_mapping = true;
            self.mapped = null;
            self.length = 0;
            self.thumbnail = null;
        }
        if (self.frame) |frame| frame.destroy();
        self.frame = null;
        if (self.session) |session| session.destroy();
        self.session = null;
        if (self.source) |source| source.destroy();
        self.source = null;
        self.freeBuffer();
        self.constraints = false;
        self.supported = false;
    }
    fn freeBuffer(self: *Window) void {
        if (self.buffer) |buffer| buffer.destroy();
        self.buffer = null;
        if (self.mapped) |memory| _ = libc.munmap(memory, self.length);
        self.mapped = null;
        self.length = 0;
    }
    fn destroy(self: *Window) void {
        self.stop();
        if (self.image) |image| image.deinit(a);
        if (self.icon) |icon| c.__icons.free(icon);
        c.g_free(self.id);
        c.g_free(self.title);
        c.g_free(self.app_id);
        self.handle.destroy();
        a.destroy(self);
    }
    fn capture(self: *Window) void {
        const client = self.client;
        if (self.session == null) {
            const source = client.sources.?.create_source(self.handle);
            self.source = source;
            const session = client.captures.?.create_session(source, 0);
            self.session = session;
            session.listen(Window, self, sessionEvent);
            return;
        }
        if (!self.constraints or !self.supported or self.frame != null or self.thumbnail != null) return;
        if (self.width == 0 or self.height == 0 or self.width > 8192 or self.height > 8192) return;
        const stride = captureStride(self.width, self.format);
        const length: usize = @as(usize, stride) * self.height;
        if (length > 64 * 1024 * 1024) return;
        if (self.buffer != null and (self.buffer_width != self.width or self.buffer_height != self.height or self.buffer_format != self.format)) self.freeBuffer();
        if (self.buffer == null) {
            const shm = helpers.shmBufferLayout(client.shm.?, "desktop-overview", length, self.width, self.height, stride, self.format) catch return;
            self.mapped = shm.memory;
            self.length = length;
            self.buffer_width = self.width;
            self.buffer_height = self.height;
            self.buffer_format = self.format;
            self.buffer = shm.buffer;
        }
        const frame = self.session.?.create_frame();
        self.frame = frame;
        frame.listen(Window, self, frameEvent);
        frame.attach_buffer(self.buffer.?);
        frame.damage_buffer(0, 0, @intCast(self.width), @intCast(self.height));
        frame.capture();
    }
    fn handleEvent(self: *Window, _: wl.ext_foreign_toplevel_handle_v1, event: wl.ext_foreign_toplevel_handle_v1.Event) void {
        switch (event) {
            .closed => closed(self),
            .done => self.client.changed(self.client.context),
            .title => |value| {
                c.g_free(self.title);
                self.title = c.g_strdup(value.title.ptr);
            },
            .app_id => |value| appId(self, value.app_id),
            .identifier => |value| {
                c.g_free(self.id);
                self.id = c.g_strdup(value.identifier.ptr);
            },
        }
    }
    fn sessionEvent(self: *Window, _: wl.ext_image_copy_capture_session_v1, event: wl.ext_image_copy_capture_session_v1.Event) void {
        switch (event) {
            .buffer_size => |value| {
                self.width = value.width;
                self.height = value.height;
            },
            .shm_format => |value| shmFormat(self, value.format),
            .done => {
                self.constraints = true;
                if (self.client.active) {
                    self.capture();
                    self.client.flush();
                }
            },
            .stopped => self.stop(),
            else => {},
        }
    }
    fn frameEvent(self: *Window, frame: wl.ext_image_copy_capture_frame_v1, event: wl.ext_image_copy_capture_frame_v1.Event) void {
        switch (event) {
            .ready => {
                frame.destroy();
                self.frame = null;
                ready(self);
            },
            .failed => {
                frame.destroy();
                self.frame = null;
                self.freeBuffer();
            },
            else => {},
        }
    }
};

pub const Client = struct {
    connection: *wire.Connection,
    registry: wl.wl_registry,
    shm: ?wl.wl_shm = null,
    list: ?wl.ext_foreign_toplevel_list_v1 = null,
    sources: ?wl.ext_foreign_toplevel_image_capture_source_manager_v1 = null,
    captures: ?wl.ext_image_copy_capture_manager_v1 = null,
    control: ?wl.dotfiles_overview_v1 = null,
    windows: std.ArrayList(*Window) = .empty,
    workspaces: [32]Workspace = @splat(.{}),
    count: u32 = 0,
    current: u32 = 0,
    pending_count: u32 = 0,
    pending_current: u32 = 0,
    pending_stacking: usize = 0,
    snapshot_dirty: bool = false,
    active: bool = false,
    streaming: bool = false,
    connected: bool = true,
    fd_source: c.guint = 0,
    context: ?*anyopaque,
    changed: *const fn (?*anyopaque) void,

    pub fn create(context: ?*anyopaque, changed: *const fn (?*anyopaque) void) !*Client {
        const connection = wire.Connection.connect(a) catch return error.NoWaylandDisplay;
        const self = a.create(Client) catch |err| {
            connection.deinit();
            return err;
        };
        const display: wl.wl_display = .{ .proxy = connection.display() };
        self.* = .{ .connection = connection, .registry = display.get_registry(), .context = context, .changed = changed };
        errdefer self.destroy();
        self.registry.listen(Client, self, registryEvent);
        connection.roundtrip() catch return error.WaylandDisconnected;
        connection.roundtrip() catch return error.WaylandDisconnected;
        if (self.shm == null or self.list == null or self.sources == null or self.captures == null or self.control == null) return error.OverviewProtocolUnavailable;
        self.fd_source = c.g_unix_fd_add(connection.getFd(), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &dispatch, self);
        return self;
    }
    pub fn destroy(self: *Client) void {
        if (self.fd_source != 0) _ = c.g_source_remove(self.fd_source);
        for (self.windows.items) |window| window.destroy();
        self.windows.deinit(a);
        if (self.control) |control| control.destroy();
        if (self.captures) |manager| manager.destroy();
        if (self.sources) |manager| manager.destroy();
        if (self.list) |list| list.destroy();
        if (self.shm) |shm| shm.destroy();
        self.registry.destroy();
        self.connection.deinit();
        a.destroy(self);
    }
    pub fn visible(self: *Client, active: bool) void {
        self.active = active;
        self.streaming = false;
        if (!active) for (self.windows.items) |window| window.stop();
        self.flush();
    }
    pub fn refresh(self: *Client) void {
        if (!self.connected) return;
        self.pending_count = 0;
        self.pending_current = self.current;
        self.snapshot_dirty = false;
        self.control.?.refresh();
        self.flush();
    }
    pub fn tick(self: *Client) void {
        if (!self.connected or !self.active) return;
        self.streaming = true;
        for (self.windows.items) |window| {
            if (window.workspace == self.current or window.sticky or window.image == null) window.capture();
        }
        self.flush();
    }
    /// Resolve desktop geometry and stacking before mapping the opening frame.
    pub fn refreshBeforeShow(self: *Client) void {
        self.refresh();
        if (self.connected) self.connection.roundtrip() catch self.disconnect();
    }
    /// Seed previews on first open without recapturing existing thumbnails
    /// during a transition. Regular live updates resume after the animation.
    pub fn captureMissing(self: *Client) void {
        if (!self.connected or !self.active) return;
        for (self.windows.items) |window| if (window.image == null) window.capture();
        self.flush();
    }
    pub fn flush(self: *Client) void {
        if (self.connected) self.connection.flush() catch self.disconnect();
    }
    fn disconnect(self: *Client) void {
        self.connected = false;
        if (self.fd_source != 0) _ = c.g_source_remove(self.fd_source);
        self.fd_source = 0;
    }
    pub fn activate(self: *Client, window: *Window) void {
        if (window.id == null) return;
        self.control.?.activate(std.mem.span(window.id));
        // The closing transition must already have the newly raised window
        // above its neighbours, even before the next periodic refresh.
        self.refreshBeforeShow();
    }
    pub fn close(self: *Client, window: *Window) void {
        if (window.id == null) return;
        self.control.?.close(std.mem.span(window.id));
        self.flush();
    }
    pub fn switchWorkspace(self: *Client, index: u32) void {
        self.control.?.switch_workspace(index);
        self.flush();
        self.refresh();
    }
    pub fn move(self: *Client, window: *Window, index: u32) void {
        if (window.id == null) return;
        self.control.?.move(std.mem.span(window.id), index);
        self.flush();
        self.refresh();
    }
    fn registryEvent(self: *Client, registry: wl.wl_registry, event: wl.wl_registry.Event) void {
        const value = switch (event) {
            .global => |global| global,
            .global_remove => return,
        };
        const s = value.interface;
        if (std.mem.eql(u8, s, "wl_shm")) {
            self.shm = registry.bind(value.name, wl.wl_shm, 1);
        } else if (std.mem.eql(u8, s, "ext_foreign_toplevel_list_v1")) {
            const list = registry.bind(value.name, wl.ext_foreign_toplevel_list_v1, 1);
            self.list = list;
            list.listen(Client, self, listEvent);
        } else if (std.mem.eql(u8, s, "ext_foreign_toplevel_image_capture_source_manager_v1")) {
            self.sources = registry.bind(value.name, wl.ext_foreign_toplevel_image_capture_source_manager_v1, 1);
        } else if (std.mem.eql(u8, s, "ext_image_copy_capture_manager_v1")) {
            self.captures = registry.bind(value.name, wl.ext_image_copy_capture_manager_v1, 1);
        } else if (std.mem.eql(u8, s, "dotfiles_overview_v1")) {
            const control = registry.bind(value.name, wl.dotfiles_overview_v1, 1);
            self.control = control;
            control.listen(Client, self, controlEvent);
        }
    }
    fn listEvent(self: *Client, _: wl.ext_foreign_toplevel_list_v1, event: wl.ext_foreign_toplevel_list_v1.Event) void {
        switch (event) {
            .toplevel => |value| {
                const window = a.create(Window) catch @panic("out of memory");
                window.* = .{ .client = self, .handle = value.toplevel };
                self.windows.append(a, window) catch @panic("out of memory");
                value.toplevel.listen(Window, window, Window.handleEvent);
            },
            .finished => {},
        }
    }
    fn controlEvent(self: *Client, _: wl.dotfiles_overview_v1, event: wl.dotfiles_overview_v1.Event) void {
        switch (event) {
            .workspace => |value| workspace(self, value.index, value.name, value.active),
            .window => |value| placement(self, value.identifier, value.workspace, value.x, value.y, value.width, value.height, value.sticky),
            .done => snapshotDone(self),
            .overview => {},
        }
    }
};

fn dispatch(_: c_int, condition: c.GIOCondition, data: c.gpointer) callconv(.c) c.gboolean {
    const self = cast(Client, data);
    const ok = condition & (c.G_IO_HUP | c.G_IO_ERR) == 0 and if (self.connection.readAndDispatch()) |_| true else |_| false;
    if (!ok) {
        self.connected = false;
        self.fd_source = 0;
        self.changed(self.context);
        return 0;
    }
    return 1;
}
fn closed(window: *Window) void {
    const client = window.client;
    for (client.windows.items, 0..) |item, i| if (item == window) {
        _ = client.windows.orderedRemove(i);
        break;
    };
    window.destroy();
    client.changed(client.context);
}
fn appId(w: *Window, value: [:0]const u8) void {
    c.g_free(w.app_id);
    w.app_id = c.g_strdup(value.ptr);
    if (w.icon) |icon| c.__icons.free(icon);
    w.icon = null;
    var filename: [1024]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&filename, "{s}.desktop", .{value}, 0) catch return;
    var info = c.g_desktop_app_info_new(path);
    if (info == null) info = c.g_desktop_app_info_new(value.ptr);
    defer if (info != null) c.g_object_unref(info);
    const icon = if (info != null) c.g_app_info_get_icon(@ptrCast(info)) else null;
    w.icon = c.__icons.loadThemed(icon, 128, null, "application-x-executable");
}
fn workspace(self: *Client, index: u32, name: [:0]const u8, active: u32) void {
    if (index >= self.workspaces.len) return;
    if (index == 0) {
        self.pending_count = 0;
        self.pending_stacking = 0;
    }
    if (c.g_strcmp0(&self.workspaces[index].name, name.ptr) != 0) {
        _ = c.g_strlcpy(&self.workspaces[index].name, name.ptr, self.workspaces[index].name.len);
        self.snapshot_dirty = true;
    }
    self.pending_count = @max(self.pending_count, index + 1);
    if (active != 0) self.pending_current = index;
}
fn placement(self: *Client, id: [:0]const u8, index: u32, x: i32, y: i32, width: i32, height: i32, sticky: u32) void {
    const stacking = self.pending_stacking;
    self.pending_stacking += 1;
    for (self.windows.items) |w| if (c.g_strcmp0(w.id, id.ptr) == 0) {
        if (w.stacking != stacking) {
            w.stacking = stacking;
            self.snapshot_dirty = true;
        }
        const is_sticky = sticky != 0;
        const geom = Rect{ .x = @floatFromInt(x), .y = @floatFromInt(y), .w = @floatFromInt(@max(1, width)), .h = @floatFromInt(@max(1, height)) };
        if (w.workspace != index or w.sticky != is_sticky or w.geometry.x != geom.x or w.geometry.y != geom.y or w.geometry.w != geom.w or w.geometry.h != geom.h) {
            w.workspace = index;
            w.sticky = is_sticky;
            w.geometry = geom;
            self.snapshot_dirty = true;
        }
        break;
    };
}
fn snapshotDone(self: *Client) void {
    if (self.count != self.pending_count or self.current != self.pending_current) {
        self.count = self.pending_count;
        self.current = self.pending_current;
        self.snapshot_dirty = true;
    }
    if (self.snapshot_dirty) {
        self.snapshot_dirty = false;
        self.changed(self.context);
    }
}
fn shmFormat(w: *Window, value: u32) void {
    if (value == formats.argb8888 or value == formats.xrgb8888 or value == formats.abgr8888 or value == formats.xbgr8888 or value == formats.bgr888) {
        w.format = value;
        w.supported = true;
    }
}
fn captureStride(width: u32, format_value: u32) u32 {
    // NVIDIA can prefer packed RGB readback. Keep every SHM row aligned.
    const bytes: u32 = if (format_value == formats.bgr888) 3 else 4;
    return std.mem.alignForward(u32, width * bytes, 4);
}
// Filtering a large capture can exceed a high-refresh display's frame budget.
// Workers only read pixels and create owned thumbnails. Wayland objects and
// window state stay on the main context. Until completion, capture() cannot
// submit another frame into the borrowed mapping.
const Thumbnail = struct {
    owner: ?*Window,
    source: @import("desktop-raster.zig").Image,
    result: ?Image = null,
    owns_mapping: bool = false,

    fn start(window: *Window, source: @import("desktop-raster.zig").Image) void {
        const self = a.create(Thumbnail) catch return;
        self.* = .{ .owner = window, .source = source };
        const task = c.g_task_new(null, null, &completed, self) orelse {
            a.destroy(self);
            return;
        };
        defer c.g_object_unref(task);
        window.thumbnail = self;
        c.g_task_set_task_data(task, self, &destroy);
        c.g_task_run_in_thread(task, &work);
    }

    fn work(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: [*c]c.GCancellable) callconv(.c) void {
        const self = cast(Thumbnail, data);
        self.result = makeImage(a, self.source) catch null;
        c.g_task_return_boolean(task, @intFromBool(self.result != null));
    }
    fn makeImage(allocator: std.mem.Allocator, source: @import("desktop-raster.zig").Image) !Image {
        const normalized = try Image.normalize(allocator, source);
        if (@max(source.width, source.height) <= 1024) return normalized;
        defer normalized.deinit(allocator);
        const ratio = 1024.0 / @as(f64, @floatFromInt(@max(source.width, source.height)));
        const width: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(source.width)) * ratio)));
        const height: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(source.height)) * ratio)));
        // Area filtering keeps text in large windows legible when minified.
        return @import("desktop-image.zig").resample(allocator, normalized, width, height);
    }
    fn completed(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Thumbnail, data);
        _ = c.g_task_propagate_boolean(@ptrCast(result), null);
        const window = self.owner orelse return;
        self.owner = null;
        window.thumbnail = null;
        const image = self.result orelse return;
        self.result = null;
        if (window.image) |old| old.deinit(a);
        window.image = image;
        // Re-arm as soon as filtering releases the shared buffer. Waiting for
        // the overview's housekeeping timer caps video at 30 Hz and adds an
        // extra timer interval whenever filtering misses a tick. The capture
        // protocol waits for source damage; static windows stay idle.
        const client = window.client;
        if (client.streaming and client.active and client.connected and (window.workspace == client.current or window.sticky)) {
            window.capture();
            client.flush();
        }
        window.client.changed(window.client.context);
    }
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self = cast(Thumbnail, data);
        if (self.result) |image| image.deinit(a);
        if (self.owns_mapping) _ = libc.munmap(@constCast(self.source.pixels.ptr), self.source.pixels.len);
        a.destroy(self);
    }
};

fn ready(w: *Window) void {
    const memory: [*]const u8 = @ptrCast(w.mapped orelse return);
    Thumbnail.start(w, .{
        .pixels = memory[0..w.length],
        .width = w.buffer_width,
        .height = w.buffer_height,
        .stride = captureStride(w.buffer_width, w.buffer_format),
        .format = switch (w.buffer_format) {
            formats.argb8888 => .argb,
            formats.xrgb8888 => .xrgb,
            formats.abgr8888 => .abgr,
            formats.xbgr8888 => .xbgr,
            // DRM BGR888 is stored as R, G, B bytes on our little-endian hosts.
            formats.bgr888 => .rgb,
            else => return,
        },
    });
}

test "NVIDIA packed RGB capture negotiates and preserves colors across padded rows" {
    var window: Window = .{ .client = undefined, .handle = undefined };
    shmFormat(&window, formats.bgr888);
    try std.testing.expect(window.supported);
    try std.testing.expectEqual(@as(u32, formats.bgr888), window.format);
    const stride = captureStride(1, window.format);
    try std.testing.expectEqual(@as(u32, 4), stride);
    try std.testing.expectEqual(@as(u32, 12), captureStride(3, window.format));
    const pixels = [_]u8{ 255, 0, 0, 0xde, 0, 0, 255, 0xad };
    const image = try Thumbnail.makeImage(std.testing.allocator, .{
        .pixels = &pixels,
        .width = 1,
        .height = 2,
        .stride = stride,
        .format = .rgb,
    });
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{ 0xffff0000, 0xff0000ff }, std.mem.bytesAsSlice(u32, image.pixels));
}

test "worker thumbnails downsample premultiplied capture pixels into independent storage" {
    const allocator = std.testing.allocator;
    const words = try allocator.alloc(u32, 2048 * 2);
    defer allocator.free(words);
    for (words, 0..) |*word, index| word.* = if (index % 2 == 0) 0x80800000 else 0x80000080;
    const image = try Thumbnail.makeImage(allocator, .{
        .pixels = std.mem.sliceAsBytes(words),
        .width = 2048,
        .height = 2,
        .stride = 2048 * 4,
        .format = .argb,
    });
    defer image.deinit(allocator);
    @memset(words, 0xff00ff00);
    try std.testing.expectEqual(@as(u32, 1024), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    for (std.mem.bytesAsSlice(u32, image.pixels)) |word| try std.testing.expectEqual(@as(u32, 0x80400040), word);
}

test "overview snapshots track focus stacking changes without changing picker order" {
    const State = struct {
        changes: usize = 0,
        fn change(data: ?*anyopaque) void {
            cast(@This(), data).changes += 1;
        }
    };
    var state: State = .{};
    var client: Client = .{ .connection = undefined, .registry = undefined, .context = &state, .changed = &State.change };
    var older: Window = .{ .client = &client, .handle = undefined, .id = c.g_strdup("older") };
    defer c.g_free(older.id);
    var newer: Window = .{ .client = &client, .handle = undefined, .id = c.g_strdup("newer") };
    defer c.g_free(newer.id);
    defer client.windows.deinit(a);
    try client.windows.appendSlice(a, &.{ &older, &newer });

    workspace(&client, 0, "1", 1);
    placement(&client, "older", 0, 0, 32, 800, 600, 0);
    placement(&client, "newer", 0, 0, 32, 800, 600, 0);
    snapshotDone(&client);
    try std.testing.expect(older.stacking < newer.stacking);
    state.changes = 0;

    // Reactivate the older window with identical geometry.
    workspace(&client, 0, "1", 1);
    placement(&client, "newer", 0, 0, 32, 800, 600, 0);
    placement(&client, "older", 0, 0, 32, 800, 600, 0);
    snapshotDone(&client);
    try std.testing.expect(older.stacking > newer.stacking);
    try std.testing.expectEqual(@as(usize, 1), state.changes);
    try std.testing.expectEqual(&older, client.windows.items[0]);
    try std.testing.expectEqual(&newer, client.windows.items[1]);
}

test "thumbnail workers publish owned pixels and discard captures detached on hide" {
    const State = struct {
        changed: bool = false,
        fn change(data: ?*anyopaque) void {
            cast(@This(), data).changed = true;
        }
    };
    var state: State = .{};
    var client: Client = .{ .connection = undefined, .registry = undefined, .context = &state, .changed = &State.change };
    var window: Window = .{ .client = &client, .handle = undefined };
    defer {
        window.stop();
        if (window.image) |image| image.deinit(a);
    }
    const fd = libc.memfd_create("thumbnail-test", libc.MFD_CLOEXEC);
    try std.testing.expect(fd >= 0);
    defer _ = libc.close(fd);
    try std.testing.expect(libc.ftruncate(fd, 16) == 0);
    const mapping = libc.mmap(null, 16, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, fd, 0);
    try std.testing.expect(mapping != null and mapping != libc.MAP_FAILED);
    const words: [*]u32 = @ptrCast(@alignCast(mapping));
    @memset(words[0..4], 0x00604020);
    window.mapped = mapping;
    window.length = 16;
    const source: @import("desktop-raster.zig").Image = .{ .pixels = @as([*]const u8, @ptrCast(mapping))[0..16], .width = 2, .height = 2, .stride = 8, .format = .xrgb };
    Thumbnail.start(&window, source);
    const deadline = c.__zig.monotonicTime() + 2_000_000;
    while (window.thumbnail != null and c.__zig.monotonicTime() < deadline) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        c.g_usleep(1000);
    }
    try std.testing.expect(window.thumbnail == null and state.changed);
    try std.testing.expectEqual(@as(u32, 0xff604020), std.mem.bytesAsSlice(u32, window.image.?.pixels)[0]);
    // The next capture may reuse the mapping only after filtering completes.
    @memset(words[0..4], 0x0000ff00);
    state.changed = false;
    Thumbnail.start(&window, source);
    try std.testing.expect(window.thumbnail != null);
    window.stop();
    try std.testing.expect(window.mapped == null and window.thumbnail == null);
    @import("tests/desktop-surface-capture.zig").pump();
    try std.testing.expect(!state.changed);
    try std.testing.expectEqual(@as(u32, 0xff604020), std.mem.bytesAsSlice(u32, window.image.?.pixels)[0]);
}
