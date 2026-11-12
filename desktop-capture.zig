//! Live, per-window captures; no screenshots of the composed desktop.
const std = @import("std");
const wayland = @import("desktop-wayland.zig");
pub const c = @import("desktop-gtk.zig");
const protocols = @import("desktop-protocols.zig");
const libc = @import("desktop-libc.zig");
pub const Image = @import("desktop-image.zig").Image;
const a = std.heap.page_allocator;
const cast = c.__zig.cast;
pub const Rect = struct { x: f64 = 0, y: f64 = 0, w: f64 = 1, h: f64 = 1 };
pub const Workspace = struct { name: [128:0]u8 = @splat(0) };

pub const Window = struct {
    client: *Client,
    handle: *protocols.ext_foreign_toplevel_handle_v1,
    id: [*c]u8 = null,
    title: [*c]u8 = null,
    app_id: [*c]u8 = null,
    workspace: u32 = 0,
    sticky: bool = false,
    stacking: usize = 0,
    geometry: Rect = .{},
    target: Rect = .{},
    icon: ?*c.GdkPixbuf = null,
    image: ?Image = null,
    thumbnail: ?*Thumbnail = null,
    source: ?*protocols.ext_image_capture_source_v1 = null,
    session: ?*protocols.ext_image_copy_capture_session_v1 = null,
    frame: ?*protocols.ext_image_copy_capture_frame_v1 = null,
    buffer: ?*c.wl_buffer = null,
    mapped: ?*anyopaque = null,
    length: usize = 0,
    buffer_width: u32 = 0,
    buffer_height: u32 = 0,
    buffer_format: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = c.WL_SHM_FORMAT_XRGB8888,
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
        if (self.frame) |frame| protocols.ext_image_copy_capture_frame_v1_destroy(frame);
        self.frame = null;
        if (self.session) |session| protocols.ext_image_copy_capture_session_v1_destroy(session);
        self.session = null;
        if (self.source) |source| protocols.ext_image_capture_source_v1_destroy(source);
        self.source = null;
        self.freeBuffer();
        self.constraints = false;
        self.supported = false;
    }
    fn freeBuffer(self: *Window) void {
        if (self.buffer) |buffer| c.wl_buffer_destroy(buffer);
        self.buffer = null;
        if (self.mapped) |memory| _ = libc.munmap(memory, self.length);
        self.mapped = null;
        self.length = 0;
    }
    fn destroy(self: *Window) void {
        self.stop();
        if (self.image) |image| image.deinit(a);
        if (self.icon) |icon| c.g_object_unref(icon);
        c.g_free(self.id);
        c.g_free(self.title);
        c.g_free(self.app_id);
        protocols.ext_foreign_toplevel_handle_v1_destroy(self.handle);
        a.destroy(self);
    }
    fn capture(self: *Window) void {
        const client = self.client;
        if (self.session == null) {
            self.source = protocols.ext_foreign_toplevel_image_capture_source_manager_v1_create_source(client.sources, self.handle);
            self.session = protocols.ext_image_copy_capture_manager_v1_create_session(client.captures, self.source, 0);
            _ = protocols.ext_image_copy_capture_session_v1_add_listener(self.session, &session_listener, self);
            return;
        }
        if (!self.constraints or !self.supported or self.frame != null or self.thumbnail != null) return;
        if (self.width == 0 or self.height == 0 or self.width > 8192 or self.height > 8192) return;
        const stride = captureStride(self.width, self.format);
        const length: usize = @as(usize, stride) * self.height;
        if (length > 64 * 1024 * 1024) return;
        if (self.buffer != null and (self.buffer_width != self.width or self.buffer_height != self.height or self.buffer_format != self.format)) self.freeBuffer();
        if (self.buffer == null) {
            const fd = libc.memfd_create("desktop-overview", libc.MFD_CLOEXEC);
            if (fd < 0) return;
            defer _ = libc.close(fd);
            if (libc.ftruncate(fd, @intCast(length)) != 0) return;
            const memory = libc.mmap(null, length, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, fd, 0);
            if (memory == libc.MAP_FAILED or memory == null) return;
            self.mapped = memory;
            self.length = length;
            self.buffer_width = self.width;
            self.buffer_height = self.height;
            self.buffer_format = self.format;
            const pool = c.wl_shm_create_pool(client.shm, fd, @intCast(length));
            self.buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(self.width), @intCast(self.height), @intCast(stride), self.format);
            c.wl_shm_pool_destroy(pool);
        }
        self.frame = protocols.ext_image_copy_capture_session_v1_create_frame(self.session);
        _ = protocols.ext_image_copy_capture_frame_v1_add_listener(self.frame, &frame_listener, self);
        protocols.ext_image_copy_capture_frame_v1_attach_buffer(self.frame, self.buffer);
        protocols.ext_image_copy_capture_frame_v1_damage_buffer(self.frame, 0, 0, @intCast(self.width), @intCast(self.height));
        protocols.ext_image_copy_capture_frame_v1_capture(self.frame);
    }
};

pub const Client = struct {
    display: *c.wl_display,
    registry: *c.wl_registry,
    shm: ?*c.wl_shm = null,
    list: ?*protocols.ext_foreign_toplevel_list_v1 = null,
    sources: ?*protocols.ext_foreign_toplevel_image_capture_source_manager_v1 = null,
    captures: ?*protocols.ext_image_copy_capture_manager_v1 = null,
    control: ?*protocols.dotfiles_overview_v1 = null,
    windows: std.ArrayList(*Window) = .empty,
    workspaces: [32]Workspace = @splat(.{}),
    count: u32 = 0,
    current: u32 = 0,
    pending_count: u32 = 0,
    pending_current: u32 = 0,
    pending_stacking: usize = 0,
    snapshot_dirty: bool = false,
    active: bool = false,
    connected: bool = true,
    fd_source: c.guint = 0,
    context: ?*anyopaque,
    changed: *const fn (?*anyopaque) void,

    pub fn create(context: ?*anyopaque, changed: *const fn (?*anyopaque) void) !*Client {
        const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
        const self = try a.create(Client);
        self.* = .{ .display = display, .registry = c.wl_display_get_registry(display).?, .context = context, .changed = changed };
        errdefer self.destroy();
        _ = c.wl_registry_add_listener(self.registry, &registry_listener, self);
        if (c.wl_display_roundtrip(display) < 0 or c.wl_display_roundtrip(display) < 0) return error.WaylandDisconnected;
        if (self.shm == null or self.list == null or self.sources == null or self.captures == null or self.control == null) return error.OverviewProtocolUnavailable;
        self.fd_source = c.g_unix_fd_add(c.wl_display_get_fd(display), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &dispatch, self);
        _ = c.wl_display_dispatch_pending(display);
        return self;
    }
    pub fn destroy(self: *Client) void {
        if (self.fd_source != 0) _ = c.g_source_remove(self.fd_source);
        for (self.windows.items) |window| window.destroy();
        self.windows.deinit(a);
        if (self.control) |control| protocols.dotfiles_overview_v1_destroy(control);
        if (self.captures) |manager| protocols.ext_image_copy_capture_manager_v1_destroy(manager);
        if (self.sources) |manager| protocols.ext_foreign_toplevel_image_capture_source_manager_v1_destroy(manager);
        if (self.list) |list| protocols.ext_foreign_toplevel_list_v1_destroy(list);
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
        a.destroy(self);
    }
    pub fn visible(self: *Client, active: bool) void {
        self.active = active;
        if (!active) for (self.windows.items) |window| window.stop();
        self.flush();
    }
    pub fn refresh(self: *Client) void {
        if (!self.connected) return;
        self.pending_count = 0;
        self.pending_current = self.current;
        self.snapshot_dirty = false;
        protocols.dotfiles_overview_v1_refresh(self.control);
        self.flush();
    }
    pub fn tick(self: *Client) void {
        if (!self.connected or !self.active) return;
        for (self.windows.items) |window| {
            if (window.workspace == self.current or window.sticky or window.image == null) window.capture();
        }
        self.flush();
    }
    /// Resolve desktop geometry and stacking before mapping the opening frame.
    pub fn refreshBeforeShow(self: *Client) void {
        self.refresh();
        if (self.connected and c.wl_display_roundtrip(self.display) < 0) self.connected = false;
    }
    /// Seed previews on first open without recapturing existing thumbnails
    /// during a transition. Regular live updates resume after the animation.
    pub fn captureMissing(self: *Client) void {
        if (!self.connected or !self.active) return;
        for (self.windows.items) |window| if (window.image == null) window.capture();
        self.flush();
    }
    pub fn flush(self: *Client) void {
        if (self.connected) _ = c.wl_display_flush(self.display);
    }
    pub fn activate(self: *Client, window: *Window) void {
        protocols.dotfiles_overview_v1_activate(self.control, window.id);
        // The closing transition must already have the newly raised window
        // above its neighbours, even before the next periodic refresh.
        self.refreshBeforeShow();
    }
    pub fn close(self: *Client, window: *Window) void {
        protocols.dotfiles_overview_v1_close(self.control, window.id);
        self.flush();
    }
    pub fn switchWorkspace(self: *Client, index: u32) void {
        protocols.dotfiles_overview_v1_switch_workspace(self.control, index);
        self.flush();
        self.refresh();
    }
    pub fn move(self: *Client, window: *Window, index: u32) void {
        protocols.dotfiles_overview_v1_move(self.control, window.id, index);
        self.flush();
        self.refresh();
    }
};

fn dispatch(_: c_int, condition: c.GIOCondition, data: c.gpointer) callconv(.c) c.gboolean {
    const self = cast(Client, data);
    if (condition & (c.G_IO_HUP | c.G_IO_ERR) != 0 or !c.__zig.dispatchWayland(self.display)) {
        self.connected = false;
        self.fd_source = 0;
        self.changed(self.context);
        return 0;
    }
    self.flush();
    return 1;
}
const registry_listener = c.wl_registry_listener{ .global = &global, .global_remove = &globalRemove };
fn global(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, _: u32) callconv(.c) void {
    const self = cast(Client, data);
    const s = std.mem.span(interface);
    if (std.mem.eql(u8, s, "wl_shm")) self.shm = @ptrCast(c.wl_registry_bind(registry, name, &wayland.wl_shm_interface, 1)) else if (std.mem.eql(u8, s, "ext_foreign_toplevel_list_v1")) {
        self.list = @ptrCast(c.wl_registry_bind(registry, name, &protocols.ext_foreign_toplevel_list_v1_interface, 1));
        _ = protocols.ext_foreign_toplevel_list_v1_add_listener(self.list, &list_listener, self);
    } else if (std.mem.eql(u8, s, "ext_foreign_toplevel_image_capture_source_manager_v1")) self.sources = @ptrCast(c.wl_registry_bind(registry, name, &protocols.ext_foreign_toplevel_image_capture_source_manager_v1_interface, 1)) else if (std.mem.eql(u8, s, "ext_image_copy_capture_manager_v1")) self.captures = @ptrCast(c.wl_registry_bind(registry, name, &protocols.ext_image_copy_capture_manager_v1_interface, 1)) else if (std.mem.eql(u8, s, "dotfiles_overview_v1")) {
        self.control = @ptrCast(c.wl_registry_bind(registry, name, &protocols.dotfiles_overview_v1_interface, 1));
        _ = protocols.dotfiles_overview_v1_add_listener(self.control, &control_listener, self);
    }
}
fn globalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}
const list_listener = protocols.ext_foreign_toplevel_list_v1_listener{ .toplevel = &toplevel, .finished = &finished };
fn toplevel(data: ?*anyopaque, _: ?*protocols.ext_foreign_toplevel_list_v1, handle: ?*protocols.ext_foreign_toplevel_handle_v1) callconv(.c) void {
    const self = cast(Client, data);
    const window = a.create(Window) catch @panic("out of memory");
    window.* = .{ .client = self, .handle = handle.? };
    self.windows.append(a, window) catch @panic("out of memory");
    _ = protocols.ext_foreign_toplevel_handle_v1_add_listener(handle, &handle_listener, window);
}
fn finished(_: ?*anyopaque, _: ?*protocols.ext_foreign_toplevel_list_v1) callconv(.c) void {}
const handle_listener = protocols.ext_foreign_toplevel_handle_v1_listener{ .closed = &closed, .done = &done, .title = &title, .app_id = &appId, .identifier = &identifier };
fn closed(data: ?*anyopaque, _: ?*protocols.ext_foreign_toplevel_handle_v1) callconv(.c) void {
    const window = cast(Window, data);
    const client = window.client;
    for (client.windows.items, 0..) |item, i| if (item == window) {
        _ = client.windows.orderedRemove(i);
        break;
    };
    window.destroy();
    client.changed(client.context);
}
fn done(data: ?*anyopaque, _: ?*protocols.ext_foreign_toplevel_handle_v1) callconv(.c) void {
    const window = cast(Window, data);
    window.client.changed(window.client.context);
}
fn title(data: ?*anyopaque, _: ?*protocols.ext_foreign_toplevel_handle_v1, value: [*c]const u8) callconv(.c) void {
    const w = cast(Window, data);
    c.g_free(w.title);
    w.title = c.g_strdup(value);
}
fn identifier(data: ?*anyopaque, _: ?*protocols.ext_foreign_toplevel_handle_v1, value: [*c]const u8) callconv(.c) void {
    const w = cast(Window, data);
    c.g_free(w.id);
    w.id = c.g_strdup(value);
}
fn appId(data: ?*anyopaque, _: ?*protocols.ext_foreign_toplevel_handle_v1, value: [*c]const u8) callconv(.c) void {
    const w = cast(Window, data);
    c.g_free(w.app_id);
    w.app_id = c.g_strdup(value);
    if (w.icon) |icon| c.g_object_unref(icon);
    var filename: [1024]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&filename, "{s}.desktop", .{std.mem.span(value)}, 0) catch return;
    var info = c.g_desktop_app_info_new(path);
    if (info == null) info = c.g_desktop_app_info_new(value);
    defer if (info != null) c.g_object_unref(info);
    const theme = c.gtk_icon_theme_get_default();
    const icon = if (info != null) c.g_app_info_get_icon(@ptrCast(info)) else null;
    const icon_info = if (icon != null) c.gtk_icon_theme_lookup_by_gicon(theme, icon, 64, 0) else null;
    defer if (icon_info != null) c.g_object_unref(icon_info);
    w.icon = if (icon_info != null) c.gtk_icon_info_load_icon(icon_info, null) else c.gtk_icon_theme_load_icon(theme, "application-x-executable", 64, 0, null);
}
const control_listener = protocols.dotfiles_overview_v1_listener{ .workspace = &workspace, .window = &placement, .done = &snapshotDone };
fn workspace(data: ?*anyopaque, _: ?*protocols.dotfiles_overview_v1, index: u32, name: [*c]const u8, active: u32) callconv(.c) void {
    const self = cast(Client, data);
    if (index >= self.workspaces.len) return;
    if (index == 0) {
        self.pending_count = 0;
        self.pending_stacking = 0;
    }
    if (c.g_strcmp0(&self.workspaces[index].name, name) != 0) {
        _ = c.g_strlcpy(&self.workspaces[index].name, name, self.workspaces[index].name.len);
        self.snapshot_dirty = true;
    }
    self.pending_count = @max(self.pending_count, index + 1);
    if (active != 0) self.pending_current = index;
}
fn placement(data: ?*anyopaque, _: ?*protocols.dotfiles_overview_v1, id: [*c]const u8, index: u32, x: i32, y: i32, width: i32, height: i32, sticky: u32) callconv(.c) void {
    const self = cast(Client, data);
    const stacking = self.pending_stacking;
    self.pending_stacking += 1;
    for (self.windows.items) |w| if (c.g_strcmp0(w.id, id) == 0) {
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
fn snapshotDone(data: ?*anyopaque, _: ?*protocols.dotfiles_overview_v1) callconv(.c) void {
    const self = cast(Client, data);
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
const session_listener = protocols.ext_image_copy_capture_session_v1_listener{ .buffer_size = &bufferSize, .shm_format = &shmFormat, .dmabuf_device = &device, .dmabuf_format = &format, .done = &constraintsDone, .stopped = &stopped };
fn bufferSize(data: ?*anyopaque, _: ?*protocols.ext_image_copy_capture_session_v1, width: u32, height: u32) callconv(.c) void {
    const w = cast(Window, data);
    w.width = width;
    w.height = height;
}
fn shmFormat(data: ?*anyopaque, _: ?*protocols.ext_image_copy_capture_session_v1, value: u32) callconv(.c) void {
    const w = cast(Window, data);
    if (value == c.WL_SHM_FORMAT_ARGB8888 or value == c.WL_SHM_FORMAT_XRGB8888 or value == c.WL_SHM_FORMAT_ABGR8888 or value == c.WL_SHM_FORMAT_XBGR8888 or value == c.WL_SHM_FORMAT_BGR888) {
        w.format = value;
        w.supported = true;
    }
}
fn captureStride(width: u32, format_value: u32) u32 {
    // NVIDIA can prefer packed RGB readback. Keep every SHM row aligned.
    const bytes: u32 = if (format_value == c.WL_SHM_FORMAT_BGR888) 3 else 4;
    return std.mem.alignForward(u32, width * bytes, 4);
}
fn device(_: ?*anyopaque, _: ?*protocols.ext_image_copy_capture_session_v1, _: [*c]c.wl_array) callconv(.c) void {}
fn format(_: ?*anyopaque, _: ?*protocols.ext_image_copy_capture_session_v1, _: u32, _: [*c]c.wl_array) callconv(.c) void {}
fn constraintsDone(data: ?*anyopaque, _: ?*protocols.ext_image_copy_capture_session_v1) callconv(.c) void {
    const window = cast(Window, data);
    window.constraints = true;
    if (window.client.active) {
        window.capture();
        window.client.flush();
    }
}
fn stopped(data: ?*anyopaque, _: ?*protocols.ext_image_copy_capture_session_v1) callconv(.c) void {
    cast(Window, data).stop();
}
const frame_listener = protocols.ext_image_copy_capture_frame_v1_listener{ .transform = &transform, .damage = &damage, .presentation_time = &presentation, .ready = &ready, .failed = &failed };
fn transform(_: ?*anyopaque, _: ?*protocols.ext_image_copy_capture_frame_v1, _: u32) callconv(.c) void {}
fn damage(_: ?*anyopaque, _: ?*protocols.ext_image_copy_capture_frame_v1, _: i32, _: i32, _: i32, _: i32) callconv(.c) void {}
fn presentation(_: ?*anyopaque, _: ?*protocols.ext_image_copy_capture_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}
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
        self.result = Image.thumbnail(a, self.source) catch null;
        c.g_task_return_boolean(task, @intFromBool(self.result != null));
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
        window.client.changed(window.client.context);
    }
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self = cast(Thumbnail, data);
        if (self.result) |image| image.deinit(a);
        if (self.owns_mapping) _ = libc.munmap(@constCast(self.source.pixels.ptr), self.source.pixels.len);
        a.destroy(self);
    }
};

fn ready(data: ?*anyopaque, frame: ?*protocols.ext_image_copy_capture_frame_v1) callconv(.c) void {
    const w = cast(Window, data);
    protocols.ext_image_copy_capture_frame_v1_destroy(frame);
    w.frame = null;
    const memory: [*]const u8 = @ptrCast(w.mapped orelse return);
    Thumbnail.start(w, .{
        .pixels = memory[0..w.length],
        .width = w.buffer_width,
        .height = w.buffer_height,
        .stride = captureStride(w.buffer_width, w.buffer_format),
        .format = switch (w.buffer_format) {
            c.WL_SHM_FORMAT_ARGB8888 => .argb,
            c.WL_SHM_FORMAT_XRGB8888 => .xrgb,
            c.WL_SHM_FORMAT_ABGR8888 => .abgr,
            c.WL_SHM_FORMAT_XBGR8888 => .xbgr,
            // DRM BGR888 is stored as R, G, B bytes on our little-endian hosts.
            c.WL_SHM_FORMAT_BGR888 => .rgb,
            else => return,
        },
    });
}
fn failed(data: ?*anyopaque, frame: ?*protocols.ext_image_copy_capture_frame_v1, _: u32) callconv(.c) void {
    const w = cast(Window, data);
    protocols.ext_image_copy_capture_frame_v1_destroy(frame);
    w.frame = null;
    w.freeBuffer();
}

test "NVIDIA packed RGB capture negotiates and preserves colors across padded rows" {
    var window: Window = .{ .client = undefined, .handle = undefined };
    shmFormat(&window, null, c.WL_SHM_FORMAT_BGR888);
    try std.testing.expect(window.supported);
    try std.testing.expectEqual(@as(u32, c.WL_SHM_FORMAT_BGR888), window.format);
    const stride = captureStride(1, window.format);
    try std.testing.expectEqual(@as(u32, 4), stride);
    try std.testing.expectEqual(@as(u32, 12), captureStride(3, window.format));
    const pixels = [_]u8{ 255, 0, 0, 0xde, 0, 0, 255, 0xad };
    const image = try Image.thumbnail(std.testing.allocator, .{
        .pixels = &pixels,
        .width = 1,
        .height = 2,
        .stride = stride,
        .format = .rgb,
    });
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{ 0xffff0000, 0xff0000ff }, std.mem.bytesAsSlice(u32, image.pixels));
}

test "overview snapshots track focus stacking changes without changing picker order" {
    const State = struct {
        changes: usize = 0,
        fn change(data: ?*anyopaque) void {
            cast(@This(), data).changes += 1;
        }
    };
    var state: State = .{};
    var client: Client = .{ .display = undefined, .registry = undefined, .context = &state, .changed = &State.change };
    var older: Window = .{ .client = &client, .handle = undefined, .id = c.g_strdup("older") };
    defer c.g_free(older.id);
    var newer: Window = .{ .client = &client, .handle = undefined, .id = c.g_strdup("newer") };
    defer c.g_free(newer.id);
    defer client.windows.deinit(a);
    try client.windows.appendSlice(a, &.{ &older, &newer });

    workspace(&client, null, 0, "1", 1);
    placement(&client, null, "older", 0, 0, 32, 800, 600, 0);
    placement(&client, null, "newer", 0, 0, 32, 800, 600, 0);
    snapshotDone(&client, null);
    try std.testing.expect(older.stacking < newer.stacking);
    state.changes = 0;

    // Reactivate the older window with identical geometry.
    workspace(&client, null, 0, "1", 1);
    placement(&client, null, "newer", 0, 0, 32, 800, 600, 0);
    placement(&client, null, "older", 0, 0, 32, 800, 600, 0);
    snapshotDone(&client, null);
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
    var client: Client = .{ .display = undefined, .registry = undefined, .context = &state, .changed = &State.change };
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
    const deadline = c.g_get_monotonic_time() + 2_000_000;
    while (window.thumbnail != null and c.g_get_monotonic_time() < deadline) {
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
