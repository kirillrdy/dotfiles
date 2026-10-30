//! Fixed desktop compositor policy. Rendering, KMS and input drivers stay in wlroots.
//! All Wayland server state belongs to the compositor thread. GTK runs on the main
//! thread so synchronous client roundtrips cannot deadlock the server.
const std = @import("std");
const c = @import("compositor-abi");
const p = @import("desktop-protocols.zig");
const heap = std.heap.page_allocator;

pub const Handle = struct {
    thread: c.pthread_t = undefined,
    ready: [2]c_int = undefined,
    stop_pipe: [2]c_int = undefined,
    show_ui: bool = false,
    stopping: std.atomic.Value(bool) = .init(false),
    socket: [108:0]u8 = @splat(0),

    pub fn start(show_ui: bool) !*Handle {
        const self = try heap.create(Handle);
        self.* = .{ .show_ui = show_ui };
        errdefer heap.destroy(self);
        if (c.pipe2(&self.ready, c.O_CLOEXEC) != 0) return error.CompositorPipe;
        defer {
            _ = c.close(self.ready[0]);
            _ = c.close(self.ready[1]);
        }
        if (c.pipe2(&self.stop_pipe, c.O_CLOEXEC) != 0) return error.CompositorPipe;
        errdefer {
            _ = c.close(self.stop_pipe[0]);
            _ = c.close(self.stop_pipe[1]);
        }
        if (c.pthread_create(&self.thread, null, &worker, self) != 0) return error.CompositorThread;
        var status: u8 = 0;
        if (c.read(self.ready[0], &status, 1) != 1 or status != 1) {
            _ = c.pthread_join(self.thread, null);
            return error.CompositorStartup;
        }
        if (c.setenv("WAYLAND_DISPLAY", &self.socket, 1) != 0) {
            self.stopping.store(true, .release);
            _ = c.write(self.stop_pipe[1], "x", 1);
            _ = c.pthread_join(self.thread, null);
            return error.CompositorEnvironment;
        }
        return self;
    }
    pub fn stop(self: *Handle) void {
        self.stopping.store(true, .release);
        _ = c.write(self.stop_pipe[1], "x", 1);
        _ = c.pthread_join(self.thread, null);
        _ = c.close(self.stop_pipe[0]);
        _ = c.close(self.stop_pipe[1]);
        heap.destroy(self);
    }
    pub fn wait(self: *Handle) void {
        _ = c.pthread_join(self.thread, null);
    }
    fn worker(ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *Handle = cast(Handle, ptr);
        var state: Server = .{ .a = heap, .show_ui = self.show_ui };
        state.init(self) catch |err| {
            std.log.err("compositor startup: {s}", .{@errorName(err)});
            _ = c.write(self.ready[1], "\x00", 1);
            return null;
        };
        defer state.deinit();
        _ = c.write(self.ready[1], "\x01", 1);
        c.wl_display_run(state.display);
        // An exit shortcut or backend shutdown must also end GTK and stop the
        // graphical session target. Normal main-thread shutdown already does so.
        if (self.show_ui and !self.stopping.load(.acquire)) _ = c.kill(c.getpid(), c.SIGTERM);
        return null;
    }
};
fn cast(comptime T: type, ptr: ?*anyopaque) *T {
    return @ptrCast(@alignCast(ptr.?));
}
fn alloc(comptime T: type, s: *Server, value: T) *T {
    const ptr = s.a.create(T) catch @panic("compositor allocation");
    ptr.* = value;
    return ptr;
}
const Hook = struct {
    listener: c.wl_listener = std.mem.zeroes(c.wl_listener),
    owner: *anyopaque,
    callback: *const fn (*anyopaque, ?*anyopaque) void,
    fn notify(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Hook = @fieldParentPtr("listener", @as(*c.wl_listener, listener));
        self.callback(self.owner, data);
    }
};
const Hooks = struct {
    entries: [32]Hook = undefined,
    len: usize = 0,
    fn add(self: *Hooks, signal: *c.wl_signal, owner: anytype, callback: *const fn (*anyopaque, ?*anyopaque) void) void {
        const h = &self.entries[self.len];
        self.len += 1;
        h.* = .{ .owner = owner, .callback = callback };
        h.listener.notify = &Hook.notify;
        c.wl_signal_add(signal, &h.listener);
    }
    fn clear(self: *Hooks) void {
        for (self.entries[0..self.len]) |*h| c.wl_list_remove(&h.listener.link);
        self.len = 0;
    }
};
const Target = struct { view: ?*View = null, layer: ?*Layer = null, locked: bool = false };
const Server = struct {
    a: std.mem.Allocator,
    show_ui: bool,
    display: *c.wl_display = undefined,
    loop: *c.wl_event_loop = undefined,
    backend: *c.wlr_backend = undefined,
    renderer: *c.wlr_renderer = undefined,
    allocator: *c.wlr_allocator = undefined,
    scene: *c.wlr_scene = undefined,
    layout: *c.wlr_output_layout = undefined,
    scene_layout: *c.wlr_scene_output_layout = undefined,
    seat: *c.wlr_seat = undefined,
    cursor: *c.wlr_cursor = undefined,
    cursors: *c.wlr_xcursor_manager = undefined,
    idle: *c.wlr_idle_notifier_v1 = undefined,
    foreign: *c.wlr_foreign_toplevel_manager_v1 = undefined,
    foreign_list: *c.wlr_ext_foreign_toplevel_list_v1 = undefined,
    output_manager: *c.wlr_output_manager_v1 = undefined,
    roots: [4]*c.wlr_scene_tree = undefined,
    windows: *c.wlr_scene_tree = undefined,
    lock_tree: *c.wlr_scene_tree = undefined,
    outputs: std.ArrayList(*Output) = .empty,
    views: std.ArrayList(*View) = .empty,
    layers: std.ArrayList(*Layer) = .empty,
    keyboards: std.ArrayList(*Keyboard) = .empty,
    hooks: Hooks = .{},
    workspace: u32 = 0,
    focused: ?*View = null,
    locked: bool = false,
    lock_serial: u64 = 0,
    lock: ?*Lock = null,
    cycling: bool = false,
    cycle_app: bool = false,
    cycle_origin: ?*View = null,
    cycle_selected: ?*View = null,
    super_alone: bool = false,
    shutting_down: bool = false,
    grabbed: ?*View = null,
    grab_box: c.wlr_box = std.mem.zeroes(c.wlr_box),
    grab_x: f64 = 0,
    grab_y: f64 = 0,
    resize_edges: u32 = 0,
    drag_icon: ?*c.wlr_scene_tree = null,
    inhibitors: std.ArrayList(*Inhibitor) = .empty,

    fn init(self: *Server, handle: *Handle) !void {
        c.wlr_log_init(c.WLR_INFO, null);
        self.display = c.wl_display_create() orelse return error.Display;
        errdefer c.wl_display_destroy(self.display);
        self.loop = c.wl_display_get_event_loop(self.display).?;
        self.backend = c.wlr_backend_autocreate(self.loop, null) orelse return error.Backend;
        errdefer c.wlr_backend_destroy(self.backend);
        self.renderer = c.wlr_renderer_autocreate(self.backend) orelse return error.Renderer;
        errdefer c.wlr_renderer_destroy(self.renderer);
        if (!c.wlr_renderer_init_wl_shm(self.renderer, self.display)) return error.SharedMemory;
        self.allocator = c.wlr_allocator_autocreate(self.backend, self.renderer) orelse return error.Allocator;
        errdefer c.wlr_allocator_destroy(self.allocator);
        self.scene = c.wlr_scene_create() orelse return error.Scene;
        self.layout = c.wlr_output_layout_create(self.display) orelse return error.Layout;
        self.scene_layout = c.wlr_scene_attach_output_layout(self.scene, self.layout).?;
        self.roots[0] = c.wlr_scene_tree_create(&self.scene.tree).?;
        self.roots[1] = c.wlr_scene_tree_create(&self.scene.tree).?;
        self.windows = c.wlr_scene_tree_create(&self.scene.tree).?;
        self.roots[2] = c.wlr_scene_tree_create(&self.scene.tree).?;
        self.roots[3] = c.wlr_scene_tree_create(&self.scene.tree).?;
        self.lock_tree = c.wlr_scene_tree_create(&self.scene.tree).?;
        c.wlr_scene_node_set_enabled(&self.lock_tree.node, false);
        if (c.wlr_renderer_get_texture_formats(self.renderer, c.WLR_BUFFER_CAP_DMABUF) != null) {
            if (c.wlr_renderer_get_drm_fd(self.renderer) >= 0) _ = c.wlr_drm_create(self.display, self.renderer);
            if (c.wlr_linux_dmabuf_v1_create_with_renderer(self.display, 4, self.renderer)) |dmabuf| c.wlr_scene_set_linux_dmabuf_v1(self.scene, dmabuf);
        }
        _ = c.wlr_compositor_create(self.display, 6, self.renderer) orelse return error.Compositor;
        _ = c.wlr_subcompositor_create(self.display);
        _ = c.wlr_data_device_manager_create(self.display);
        _ = c.wlr_primary_selection_v1_device_manager_create(self.display);
        _ = c.wlr_data_control_manager_v1_create(self.display);
        _ = c.wlr_viewporter_create(self.display);
        _ = c.wlr_fractional_scale_manager_v1_create(self.display, 1);
        _ = c.wlr_single_pixel_buffer_manager_v1_create(self.display);
        _ = c.wlr_xdg_output_manager_v1_create(self.display, self.layout);
        _ = c.wlr_presentation_create(self.display, self.backend, 2);
        _ = c.wlr_screencopy_manager_v1_create(self.display);
        _ = c.wlr_ext_image_copy_capture_manager_v1_create(self.display, 1);
        _ = c.wlr_ext_output_image_capture_source_manager_v1_create(self.display, 1);
        const capture: *c.wlr_ext_foreign_toplevel_image_capture_source_manager_v1 = c.wlr_ext_foreign_toplevel_image_capture_source_manager_v1_create(self.display, 1).?;
        self.hooks.add(&capture.events.new_request, self, &captureRequest);
        self.foreign = c.wlr_foreign_toplevel_manager_v1_create(self.display).?;
        self.foreign_list = c.wlr_ext_foreign_toplevel_list_v1_create(self.display, 1).?;
        self.idle = c.wlr_idle_notifier_v1_create(self.display).?;
        self.seat = c.wlr_seat_create(self.display, "seat0").?;
        self.cursor = c.wlr_cursor_create().?;
        c.wlr_cursor_attach_output_layout(self.cursor, self.layout);
        self.cursors = c.wlr_xcursor_manager_create("Adwaita", 24).?;
        self.hooks.add(&self.backend.events.new_output, self, &newOutput);
        self.hooks.add(&self.backend.events.new_input, self, &newInput);
        self.hooks.add(&self.cursor.events.motion, self, &motion);
        self.hooks.add(&self.cursor.events.motion_absolute, self, &absolute);
        self.hooks.add(&self.cursor.events.button, self, &button);
        self.hooks.add(&self.cursor.events.axis, self, &axis);
        self.hooks.add(&self.cursor.events.frame, self, &pointerFrame);
        self.hooks.add(&self.seat.events.request_set_cursor, self, &setCursor);
        self.hooks.add(&self.seat.events.request_set_selection, self, &selection);
        self.hooks.add(&self.seat.events.request_start_drag, self, &startDrag);
        const inhibition: *c.wlr_idle_inhibit_manager_v1 = c.wlr_idle_inhibit_v1_create(self.display).?;
        self.hooks.add(&inhibition.events.new_inhibitor, self, &newInhibitor);
        self.hooks.add(&self.seat.events.request_set_primary_selection, self, &primarySelection);
        const shapes: *c.wlr_cursor_shape_manager_v1 = c.wlr_cursor_shape_manager_v1_create(self.display, 1).?;
        self.hooks.add(&shapes.events.request_set_shape, self, &setShape);
        const xdg: *c.wlr_xdg_shell = c.wlr_xdg_shell_create(self.display, 6).?;
        self.hooks.add(&xdg.events.new_toplevel, self, &newView);
        self.hooks.add(&xdg.events.new_popup, self, &newPopup);
        const layer: *c.wlr_layer_shell_v1 = c.wlr_layer_shell_v1_create(self.display, 4).?;
        self.hooks.add(&layer.events.new_surface, self, &newLayer);
        const decorations: *c.wlr_xdg_decoration_manager_v1 = c.wlr_xdg_decoration_manager_v1_create(self.display).?;
        self.hooks.add(&decorations.events.new_toplevel_decoration, self, &decoration);
        const kde = c.wlr_server_decoration_manager_create(self.display).?;
        c.wlr_server_decoration_manager_set_default_mode(kde, c.WLR_SERVER_DECORATION_MANAGER_MODE_CLIENT);
        const activation: *c.wlr_xdg_activation_v1 = c.wlr_xdg_activation_v1_create(self.display).?;
        self.hooks.add(&activation.events.request_activate, self, &activate);
        const locks: *c.wlr_session_lock_manager_v1 = c.wlr_session_lock_manager_v1_create(self.display).?;
        self.hooks.add(&locks.events.new_lock, self, &newLock);
        const vk: *c.wlr_virtual_keyboard_manager_v1 = c.wlr_virtual_keyboard_manager_v1_create(self.display).?;
        self.hooks.add(&vk.events.new_virtual_keyboard, self, &virtualKeyboard);
        const vp: *c.wlr_virtual_pointer_manager_v1 = c.wlr_virtual_pointer_manager_v1_create(self.display).?;
        self.hooks.add(&vp.events.new_virtual_pointer, self, &virtualPointer);
        self.output_manager = c.wlr_output_manager_v1_create(self.display).?;
        self.hooks.add(&self.output_manager.events.apply, self, &applyOutputs);
        self.hooks.add(&self.output_manager.events.@"test", self, &testOutputs);
        _ = c.wl_global_create(self.display, @ptrCast(&p.dotfiles_overview_v1_interface), 1, self, &Overview.bind) orelse return error.Overview;
        _ = c.wl_event_loop_add_fd(self.loop, handle.stop_pipe[0], c.WL_EVENT_READABLE, &stopEvent, self) orelse return error.StopEvent;
        const socket = c.wl_display_add_socket_auto(self.display) orelse return error.Socket;
        const name = std.mem.span(socket);
        @memcpy(handle.socket[0..name.len], name);
        if (!c.wlr_backend_start(self.backend)) return error.StartBackend;
        std.log.info("desktop compositor ready on {s}", .{name});
    }
    fn deinit(self: *Server) void {
        self.shutting_down = true;
        c.wl_display_destroy_clients(self.display);
        self.hooks.clear();
        c.wlr_backend_destroy(self.backend);
        c.wlr_scene_node_destroy(&self.scene.tree.node);
        c.wlr_xcursor_manager_destroy(self.cursors);
        c.wlr_cursor_destroy(self.cursor);
        c.wlr_allocator_destroy(self.allocator);
        c.wlr_renderer_destroy(self.renderer);
        c.wl_display_destroy(self.display);
        self.outputs.deinit(self.a);
        self.views.deinit(self.a);
        self.layers.deinit(self.a);
        self.keyboards.deinit(self.a);
        self.inhibitors.deinit(self.a);
    }
    fn stopEvent(_: c_int, _: u32, ptr: ?*anyopaque) callconv(.c) c_int {
        c.wl_display_terminate(cast(Server, ptr).display);
        return 0;
    }
    fn activity(self: *Server) void {
        c.wlr_idle_notifier_v1_notify_activity(self.idle, self.seat);
    }
    fn outputAt(self: *Server, x: f64, y: f64) ?*Output {
        const output = c.wlr_output_layout_output_at(self.layout, x, y);
        for (self.outputs.items) |o| if (o.wlr == output) return o;
        return if (self.outputs.items.len > 0) self.outputs.items[0] else null;
    }
    fn keyboardFocus(self: *Server, surface: ?*c.wlr_surface) void {
        if (surface == null) {
            c.wlr_seat_keyboard_notify_clear_focus(self.seat);
            return;
        }
        if (c.wlr_seat_get_keyboard(self.seat)) |kb| c.wlr_seat_keyboard_notify_enter(self.seat, surface, &kb.*.keycodes, kb.*.num_keycodes, &kb.*.modifiers);
    }
    fn focus(self: *Server, view: ?*View) void {
        if (self.locked) return;
        if (self.focused) |old| if (old.alive) {
            _ = c.wlr_xdg_toplevel_set_activated(old.xdg, false);
            if (old.foreign) |f| c.wlr_foreign_toplevel_handle_v1_set_activated(f, false);
        };
        self.focused = view;
        if (view) |v| {
            if (!v.mapped) return;
            if (v.workspace != self.workspace) self.switchWorkspace(v.workspace);
            c.wlr_scene_node_raise_to_top(&v.tree.node);
            _ = c.wlr_xdg_toplevel_set_activated(v.xdg, true);
            if (v.foreign) |f| c.wlr_foreign_toplevel_handle_v1_set_activated(f, true);
            self.keyboardFocus(v.xdg.base.*.surface);
            if (!self.cycling) {
                remove(*View, &self.views, v);
                self.views.insert(self.a, 0, v) catch @panic("view ordering");
            }
        } else self.keyboardFocus(null);
    }
    fn refocus(self: *Server) void {
        for (self.views.items) |v| if (v.mapped and v.workspace == self.workspace) {
            self.focus(v);
            return;
        };
        self.focus(null);
    }
    fn switchWorkspace(self: *Server, index: u32) void {
        if (self.locked or index >= 4) return;
        self.workspace = index;
        self.updateInhibition();
        for (self.views.items) |v| c.wlr_scene_node_set_enabled(&v.tree.node, v.mapped and v.workspace == index);
    }
    fn representative(self: *Server, view: *View) *View {
        for (self.views.items) |v| if (v.mapped and v.workspace == self.workspace and sameApp(view, v)) return v;
        return view;
    }
    fn cycle(self: *Server, reverse: bool, same_app: bool) void {
        if (!self.cycling) {
            self.cycle_origin = self.focused;
            self.cycle_selected = self.focused;
            self.cycling = true;
        }
        self.cycle_app = same_app;
        const views = self.views.items;
        const selected = self.cycle_selected;
        const start_view = if (!same_app and selected != null) self.representative(selected.?) else selected;
        var start: usize = 0;
        for (views, 0..) |v, i| if (v == start_view) {
            start = i;
            break;
        };
        for (1..views.len + 1) |offset| {
            const i = if (reverse) (start + views.len - offset % views.len) % views.len else (start + offset) % views.len;
            const v = views[i];
            if (!v.mapped or v.workspace != self.workspace) continue;
            if (!same_app and self.representative(v) != v) continue;
            if (same_app) if (selected) |origin| if (!sameApp(origin, v)) continue;
            self.cycle_selected = v;
            self.showSwitcher();
            return;
        }
        if (same_app) self.cycle(reverse, false) else self.finishCycle(true);
    }
    fn showSwitcher(self: *Server) void {
        const ui = @import("desktop-switcher.zig");
        var snapshot: ui.Snapshot = .{ .visible = true, .window_selection = self.cycle_app };
        if (self.outputAt(self.cursor.x, self.cursor.y)) |output| {
            snapshot.output_x = output.box.x + @divTrunc(output.box.width, 2);
            snapshot.output_y = output.box.y + @divTrunc(output.box.height, 2);
        }
        for (self.views.items) |v| {
            if (!v.mapped or v.workspace != self.workspace or snapshot.len == snapshot.items.len) continue;
            var item = &snapshot.items[snapshot.len];
            const app_id = if (v.xdg.app_id != null) std.mem.span(v.xdg.app_id) else "";
            const label = if (v.xdg.title != null) std.mem.span(v.xdg.title) else app_id;
            const id = if (v.listed) |listed| std.mem.span(listed.identifier) else "";
            @memcpy(item.id[0..@min(id.len, 255)], id[0..@min(id.len, 255)]);
            @memcpy(item.app_id[0..@min(app_id.len, 255)], app_id[0..@min(app_id.len, 255)]);
            @memcpy(item.title[0..@min(label.len, 255)], label[0..@min(label.len, 255)]);
            item.selected = v == self.cycle_selected;
            snapshot.len += 1;
        }
        if (self.show_ui) ui.publish(snapshot);
    }
    fn finishCycle(self: *Server, cancel: bool) void {
        const selected = if (cancel) self.cycle_origin else self.cycle_selected;
        self.cycling = false;
        self.cycle_origin = null;
        self.cycle_selected = null;
        if (selected) |v| if (v.alive and v.mapped) self.focus(v);
        if (self.show_ui) @import("desktop-switcher.zig").publish(.{});
    }
    fn pointer(self: *Server, time: u32) void {
        if (self.drag_icon) |icon| c.wlr_scene_node_set_position(&icon.node, @intFromFloat(self.cursor.x), @intFromFloat(self.cursor.y));
        if (self.grabbed) |v| {
            const dx: i32 = @intFromFloat(self.cursor.x - self.grab_x);
            const dy: i32 = @intFromFloat(self.cursor.y - self.grab_y);
            var box = self.grab_box;
            if (self.resize_edges == 0) {
                box.x += dx;
                box.y += dy;
            } else {
                if (self.resize_edges & c.WLR_EDGE_LEFT != 0) {
                    box.x += dx;
                    box.width -= dx;
                }
                if (self.resize_edges & c.WLR_EDGE_RIGHT != 0) box.width += dx;
                if (self.resize_edges & c.WLR_EDGE_TOP != 0) {
                    box.y += dy;
                    box.height -= dy;
                }
                if (self.resize_edges & c.WLR_EDGE_BOTTOM != 0) box.height += dy;
                box.width = @max(@as(i32, @intCast(v.xdg.current.min_width)), @max(64, box.width));
                box.height = @max(@as(i32, @intCast(v.xdg.current.min_height)), @max(48, box.height));
            }
            v.floating_box = box;
            v.configure();
            return;
        }
        var sx: f64 = 0;
        var sy: f64 = 0;
        const point = self.hit(&sx, &sy);
        if (point.surface) |surface| {
            c.wlr_seat_pointer_notify_enter(self.seat, surface, sx, sy);
            c.wlr_seat_pointer_notify_motion(self.seat, time, sx, sy);
        } else {
            c.wlr_seat_pointer_clear_focus(self.seat);
            c.wlr_cursor_set_xcursor(self.cursor, self.cursors, "default");
        }
    }
    fn hit(self: *Server, sx: *f64, sy: *f64) struct { surface: ?*c.wlr_surface = null, target: ?*Target = null } {
        const root = if (self.locked) &self.lock_tree.node else &self.scene.tree.node;
        const node: *c.wlr_scene_node = c.wlr_scene_node_at(root, self.cursor.x, self.cursor.y, sx, sy) orelse return .{};
        if (node.type != c.WLR_SCENE_NODE_BUFFER) return .{};
        const surface: *c.wlr_scene_surface = c.wlr_scene_surface_try_from_buffer(c.wlr_scene_buffer_from_node(node)) orelse return .{};
        var tree = node.parent;
        while (tree != null) : (tree = tree.*.node.parent) if (tree.*.node.data) |ptr| return .{ .surface = surface.surface, .target = cast(Target, ptr) };
        return .{ .surface = surface.surface };
    }
    fn newOutput(ptr: *anyopaque, data: ?*anyopaque) void {
        Output.create(cast(Server, ptr), cast(c.wlr_output, data));
    }
    fn newView(ptr: *anyopaque, data: ?*anyopaque) void {
        View.create(cast(Server, ptr), cast(c.wlr_xdg_toplevel, data));
    }
    fn newLayer(ptr: *anyopaque, data: ?*anyopaque) void {
        Layer.create(cast(Server, ptr), cast(c.wlr_layer_surface_v1, data));
    }
    fn newPopup(ptr: *anyopaque, data: ?*anyopaque) void {
        Popup.create(cast(Server, ptr), cast(c.wlr_xdg_popup, data));
    }
    fn newInput(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Server, ptr);
        const device = cast(c.wlr_input_device, data);
        switch (device.type) {
            c.WLR_INPUT_DEVICE_KEYBOARD => Keyboard.create(self, c.wlr_keyboard_from_input_device(device).?, false),
            c.WLR_INPUT_DEVICE_POINTER => {
                if (c.wlr_input_device_is_libinput(device)) {
                    const libinput = c.wlr_libinput_get_device_handle(device);
                    if (c.libinput_device_config_tap_get_finger_count(libinput) > 0) {
                        _ = c.libinput_device_config_tap_set_enabled(libinput, c.LIBINPUT_CONFIG_TAP_DISABLED);
                        _ = c.libinput_device_config_scroll_set_natural_scroll_enabled(libinput, 1);
                    }
                }
                c.wlr_cursor_attach_input_device(self.cursor, device);
            },
            else => {},
        }
        self.capabilities();
    }
    fn capabilities(self: *Server) void {
        c.wlr_seat_set_capabilities(self.seat, @as(u32, c.WL_SEAT_CAPABILITY_POINTER) | if (self.keyboards.items.len > 0) @as(u32, c.WL_SEAT_CAPABILITY_KEYBOARD) else 0);
    }
    fn virtualKeyboard(ptr: *anyopaque, data: ?*anyopaque) void {
        Keyboard.create(cast(Server, ptr), &cast(c.wlr_virtual_keyboard_v1, data).keyboard, true);
    }
    fn virtualPointer(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Server, ptr);
        const event = cast(c.wlr_virtual_pointer_v1_new_pointer_event, data);
        c.wlr_cursor_attach_input_device(self.cursor, &event.new_pointer.*.pointer.base);
        if (event.suggested_output != null) c.wlr_cursor_map_input_to_output(self.cursor, &event.new_pointer.*.pointer.base, event.suggested_output);
        self.capabilities();
    }
    fn motion(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Server, ptr);
        const e = cast(c.wlr_pointer_motion_event, data);
        self.activity();
        c.wlr_cursor_move(self.cursor, &e.pointer.*.base, e.delta_x, e.delta_y);
        self.pointer(e.time_msec);
    }
    fn absolute(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Server, ptr);
        const e = cast(c.wlr_pointer_motion_absolute_event, data);
        self.activity();
        c.wlr_cursor_warp_absolute(self.cursor, &e.pointer.*.base, e.x, e.y);
        self.pointer(e.time_msec);
    }
    fn button(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Server, ptr);
        const e = cast(c.wlr_pointer_button_event, data);
        self.activity();
        if (e.state == c.WL_POINTER_BUTTON_STATE_RELEASED) self.grabbed = null;
        var sx: f64 = 0;
        var sy: f64 = 0;
        if (e.state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
            const point = self.hit(&sx, &sy);
            if (point.target) |target| {
                if (target.view) |v| self.focus(v);
                if (target.layer) |l| if (!self.locked and l.wlr.current.keyboard_interactive != c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE) self.keyboardFocus(l.wlr.surface);
            }
        }
        _ = c.wlr_seat_pointer_notify_button(self.seat, e.time_msec, e.button, e.state);
    }
    fn axis(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Server, ptr);
        const e = cast(c.wlr_pointer_axis_event, data);
        self.activity();
        c.wlr_seat_pointer_notify_axis(self.seat, e.time_msec, e.orientation, e.delta, e.delta_discrete, e.source, e.relative_direction);
    }
    fn pointerFrame(ptr: *anyopaque, _: ?*anyopaque) void {
        c.wlr_seat_pointer_notify_frame(cast(Server, ptr).seat);
    }
    fn startDrag(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Server, ptr);
        const event = cast(c.wlr_seat_request_start_drag_event, data);
        if (!self.locked and c.wlr_seat_validate_pointer_grab_serial(self.seat, event.origin, event.serial)) {
            c.wlr_seat_start_pointer_drag(self.seat, event.drag, event.serial);
            Drag.create(self, event.drag);
        } else if (event.drag.*.source != null) c.wlr_data_source_destroy(event.drag.*.source);
    }
    fn newInhibitor(ptr: *anyopaque, data: ?*anyopaque) void {
        Inhibitor.create(cast(Server, ptr), cast(c.wlr_idle_inhibitor_v1, data));
    }
    fn updateInhibition(self: *Server) void {
        var inhibited = false;
        if (!self.locked) for (self.inhibitors.items) |inhibitor| {
            const root = c.wlr_surface_get_root_surface(inhibitor.wlr.surface);
            if (root == null or !root.*.mapped) continue;
            for (self.views.items) |v| if (v.mapped and v.workspace == self.workspace and v.xdg.base.*.surface == root) {
                inhibited = true;
                break;
            };
        };
        c.wlr_idle_notifier_v1_set_inhibited(self.idle, inhibited);
    }
    fn setCursor(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Server, ptr);
        const e = cast(c.wlr_seat_pointer_request_set_cursor_event, data);
        if (self.seat.pointer_state.focused_client == e.seat_client) c.wlr_cursor_set_surface(self.cursor, e.surface, e.hotspot_x, e.hotspot_y);
    }
    fn setShape(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Server, ptr);
        const e = cast(c.wlr_cursor_shape_manager_v1_request_set_shape_event, data);
        if (self.seat.pointer_state.focused_client == e.seat_client) c.wlr_cursor_set_xcursor(self.cursor, self.cursors, c.wlr_cursor_shape_v1_name(e.shape));
    }
    fn selection(ptr: *anyopaque, data: ?*anyopaque) void {
        const e = cast(c.wlr_seat_request_set_selection_event, data);
        c.wlr_seat_set_selection(cast(Server, ptr).seat, e.source, e.serial);
    }
    fn primarySelection(ptr: *anyopaque, data: ?*anyopaque) void {
        const e = cast(c.wlr_seat_request_set_primary_selection_event, data);
        c.wlr_seat_set_primary_selection(cast(Server, ptr).seat, e.source, e.serial);
    }
    fn decoration(_: *anyopaque, data: ?*anyopaque) void {
        Decoration.create(cast(c.wlr_xdg_toplevel_decoration_v1, data));
    }
    fn activate(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Server, ptr);
        const e = cast(c.wlr_xdg_activation_v1_request_activate_event, data);
        for (self.views.items) |v| if (v.xdg.base.*.surface == e.surface and v.mapped) {
            self.focus(v);
            break;
        };
    }
    fn captureRequest(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Server, ptr);
        const e = cast(c.wlr_ext_foreign_toplevel_image_capture_source_manager_v1_request, data);
        if (self.locked or e.toplevel_handle == null or e.toplevel_handle.*.data == null) return;
        const view = cast(View, e.toplevel_handle.*.data);
        if (view.capture == null) {
            if (view.capture_scene == null) {
                view.capture_scene = c.wlr_scene_create();
                if (view.capture_scene) |scene| _ = c.wlr_scene_xdg_surface_create(&scene.tree, view.xdg.base);
            }
            if (view.capture_scene) |scene| view.capture = c.wlr_ext_image_capture_source_v1_create_with_scene_node(&scene.tree.node, self.loop, self.allocator, self.renderer);
            if (view.capture) |source| view.capture_hook.add(&source.events.destroy, view, &View.captureDestroyed);
        }
        if (view.capture) |source| _ = c.wlr_ext_foreign_toplevel_image_capture_source_manager_v1_request_accept(e, source);
    }
    fn newLock(ptr: *anyopaque, data: ?*anyopaque) void {
        Lock.create(cast(Server, ptr), cast(c.wlr_session_lock_v1, data));
    }
    fn publishOutputs(self: *Server) void {
        if (self.shutting_down) return;
        const config = c.wlr_output_configuration_v1_create().?;
        for (self.outputs.items) |output| {
            const head: *c.wlr_output_configuration_head_v1 = c.wlr_output_configuration_head_v1_create(config, output.wlr).?;
            head.state.x = output.box.x;
            head.state.y = output.box.y;
        }
        c.wlr_output_manager_v1_set_configuration(self.output_manager, config);
    }
    fn applyOutputs(ptr: *anyopaque, data: ?*anyopaque) void {
        cast(Server, ptr).configureOutputs(cast(c.wlr_output_configuration_v1, data), true);
    }
    fn testOutputs(ptr: *anyopaque, data: ?*anyopaque) void {
        cast(Server, ptr).configureOutputs(cast(c.wlr_output_configuration_v1, data), false);
    }
    fn configureOutputs(self: *Server, config: *c.wlr_output_configuration_v1, apply: bool) void {
        defer c.wlr_output_configuration_v1_destroy(config);
        var count: usize = 0;
        const states = c.wlr_output_configuration_v1_build_state(config, &count);
        if (states == null) {
            c.wlr_output_configuration_v1_send_failed(config);
            return;
        }
        defer {
            for (states[0..count]) |*output| c.wlr_output_state_finish(&output.base);
            c.free(states);
        }
        var ok = c.wlr_backend_test(self.backend, states, count);
        if (ok and apply) {
            ok = c.wlr_backend_commit(self.backend, states, count);
            if (ok) {
                var link = config.heads.next;
                while (link != &config.heads) : (link = link.*.next) {
                    const head: *c.wlr_output_configuration_head_v1 = @fieldParentPtr("link", @as(*c.wl_list, link));
                    if (head.state.enabled) _ = c.wlr_output_layout_add(self.layout, head.state.output, head.state.x, head.state.y) else c.wlr_output_layout_remove(self.layout, head.state.output);
                }
                for (self.outputs.items) |output| output.arrange();
                self.publishOutputs();
            }
        }
        if (ok) c.wlr_output_configuration_v1_send_succeeded(config) else c.wlr_output_configuration_v1_send_failed(config);
    }
};
fn remove(comptime T: type, list: *std.ArrayList(T), value: T) void {
    for (list.items, 0..) |item, i| if (item == value) {
        _ = list.orderedRemove(i);
        return;
    };
}
fn sameApp(a: *View, b: *View) bool {
    return a == b or (a.xdg.app_id != null and a.xdg.app_id[0] != 0 and same(a.xdg.app_id, b.xdg.app_id));
}
fn same(a: [*c]const u8, b: [*c]const u8) bool {
    return std.mem.eql(u8, if (a != null) std.mem.span(a) else "", if (b != null) std.mem.span(b) else "");
}

const Output = struct {
    s: *Server,
    wlr: *c.wlr_output,
    scene: *c.wlr_scene_output,
    lock_serial: u64 = 0,
    box: c.wlr_box = std.mem.zeroes(c.wlr_box),
    usable: c.wlr_box = std.mem.zeroes(c.wlr_box),
    hooks: Hooks = .{},
    fn create(s: *Server, wlr: *c.wlr_output) void {
        if (!c.wlr_output_init_render(wlr, s.allocator, s.renderer)) return;
        var state: c.wlr_output_state = undefined;
        c.wlr_output_state_init(&state);
        defer c.wlr_output_state_finish(&state);
        c.wlr_output_state_set_enabled(&state, true);
        if (c.wlr_output_preferred_mode(wlr)) |mode| c.wlr_output_state_set_mode(&state, mode);
        if (same(wlr.name, "eDP-1")) c.wlr_output_state_set_scale(&state, 1.625);
        if (!c.wlr_output_commit_state(wlr, &state)) return;
        const layout = c.wlr_output_layout_add_auto(s.layout, wlr) orelse return;
        const self = alloc(Output, s, .{ .s = s, .wlr = wlr, .scene = c.wlr_scene_output_create(s.scene, wlr).? });
        c.wlr_scene_output_layout_add_output(s.scene_layout, layout, self.scene);
        self.hooks.add(&wlr.events.frame, self, &frame);
        self.hooks.add(&wlr.events.request_state, self, &requestState);
        self.hooks.add(&wlr.events.destroy, self, &destroy);
        s.outputs.append(s.a, self) catch @panic("outputs");
        _ = c.wlr_xcursor_manager_load(s.cursors, wlr.scale);
        self.arrange();
        s.publishOutputs();
        if (s.locked) if (s.lock) |lock| lock.blankOutput(self);
    }
    fn arrange(self: *Output) void {
        c.wlr_output_layout_get_box(self.s.layout, self.wlr, &self.box);
        self.usable = self.box;
        // Exclusive layers reserve panel space before ordinary layers are laid out.
        for ([_]bool{ true, false }) |exclusive| {
            var n: usize = 4;
            while (n > 0) {
                n -= 1;
                for (self.s.layers.items) |layer| {
                    if (layer.wlr.output != self.wlr or layer.wlr.current.layer != n) continue;
                    if ((layer.wlr.current.exclusive_zone > 0) != exclusive) continue;
                    if (layer.wlr.initialized) c.wlr_scene_layer_surface_v1_configure(layer.scene, &self.box, &self.usable);
                }
            }
        }
        for (self.s.views.items) |v| if (v.output == self and v.alive) v.configure();
        if (self.s.locked) if (self.s.lock) |lock| lock.resize(self);
    }
    fn frame(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Output, ptr);
        const committed = c.wlr_scene_output_commit(self.scene, null);
        if (committed and self.s.locked) if (self.s.lock) |lock| {
            self.lock_serial = self.s.lock_serial;
            lock.acknowledge();
        };
        var now: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now);
        c.wlr_scene_output_send_frame_done(self.scene, &now);
    }
    fn requestState(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Output, ptr);
        const e = cast(c.wlr_output_event_request_state, data);
        if (c.wlr_output_commit_state(self.wlr, e.state)) {
            self.arrange();
            self.s.publishOutputs();
        }
    }
    fn destroy(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Output, ptr);
        defer self.s.a.destroy(self);
        self.hooks.clear();
        remove(*Output, &self.s.outputs, self);
        for (self.s.views.items) |v| if (v.output == self) {
            v.output = if (self.s.outputs.items.len > 0) self.s.outputs.items[0] else null;
            v.configure();
        };
        if (self.s.lock) |lock| {
            var i: usize = 0;
            while (i < lock.blanks.items.len) {
                if (lock.blanks.items[i].output == self.wlr) {
                    const blank = lock.blanks.orderedRemove(i);
                    c.wlr_scene_node_destroy(&blank.rect.node);
                } else i += 1;
            }
            lock.acknowledge();
        }
        self.s.publishOutputs();
    }
};
const View = struct {
    s: *Server,
    xdg: *c.wlr_xdg_toplevel,
    tree: *c.wlr_scene_tree,
    output: ?*Output,
    target: Target = .{},
    hooks: Hooks = .{},
    capture_hook: Hooks = .{},
    capture_scene: ?*c.wlr_scene = null,
    capture: ?*c.wlr_ext_image_capture_source_v1 = null,
    foreign: ?*c.wlr_foreign_toplevel_handle_v1 = null,
    listed: ?*c.wlr_ext_foreign_toplevel_handle_v1 = null,
    mapped: bool = false,
    alive: bool = true,
    workspace: u32,
    fullscreen: bool = false,
    maximized: bool = true,
    floating_box: ?c.wlr_box = null,
    tile: enum { none, left, right } = .none,
    fn create(s: *Server, xdg: *c.wlr_xdg_toplevel) void {
        const self = alloc(View, s, .{ .s = s, .xdg = xdg, .tree = c.wlr_scene_xdg_surface_create(s.windows, xdg.base).?, .workspace = s.workspace, .output = s.outputAt(s.cursor.x, s.cursor.y) });
        self.target.view = self;
        self.tree.node.data = &self.target;
        xdg.base.*.data = self.tree;
        self.hooks.add(&xdg.base.*.surface.*.events.map, self, &map);
        self.hooks.add(&xdg.base.*.surface.*.events.unmap, self, &unmap);
        self.hooks.add(&xdg.base.*.surface.*.events.commit, self, &commit);
        self.hooks.add(&xdg.events.destroy, self, &destroy);
        self.hooks.add(&xdg.events.request_maximize, self, &maximize);
        self.hooks.add(&xdg.events.request_move, self, &requestMove);
        self.hooks.add(&xdg.events.request_resize, self, &requestResize);
        self.hooks.add(&xdg.events.request_fullscreen, self, &fullscreenRequest);
        self.hooks.add(&xdg.events.set_title, self, &title);
        self.hooks.add(&xdg.events.set_app_id, self, &title);
        s.views.append(s.a, self) catch @panic("views");
    }
    fn configure(self: *View) void {
        if (!self.xdg.base.*.initialized) return;
        const output = self.output orelse {
            _ = c.wlr_xdg_toplevel_set_size(self.xdg, 0, 0);
            return;
        };
        var box = if (self.fullscreen) output.box else if (!self.maximized and self.floating_box != null) self.floating_box.? else output.usable;
        if (self.tile != .none and !self.fullscreen) {
            box.width = @divTrunc(box.width, 2);
            if (self.tile == .right) box.x += box.width;
        }
        const dialog = self.xdg.parent != null or (self.xdg.current.max_width > 0 and self.xdg.current.max_height > 0 and self.xdg.current.min_width == self.xdg.current.max_width and self.xdg.current.min_height == self.xdg.current.max_height);
        if (dialog and !self.fullscreen) {
            _ = c.wlr_xdg_toplevel_set_maximized(self.xdg, false);
            _ = c.wlr_xdg_toplevel_set_size(self.xdg, 0, 0);
            const geo = self.xdg.base.*.geometry;
            c.wlr_scene_node_set_position(&self.tree.node, box.x + @divTrunc(box.width - geo.width, 2), box.y + @divTrunc(box.height - geo.height, 2));
        } else {
            _ = c.wlr_xdg_toplevel_set_maximized(self.xdg, self.maximized and !self.fullscreen and self.tile == .none);
            _ = c.wlr_xdg_toplevel_set_fullscreen(self.xdg, self.fullscreen);
            _ = c.wlr_xdg_toplevel_set_size(self.xdg, @intCast(@max(1, box.width)), @intCast(@max(1, box.height)));
            c.wlr_scene_node_set_position(&self.tree.node, box.x, box.y);
        }
        if (self.foreign) |f| {
            c.wlr_foreign_toplevel_handle_v1_set_maximized(f, self.maximized);
            c.wlr_foreign_toplevel_handle_v1_set_fullscreen(f, self.fullscreen);
        }
    }
    fn map(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(View, ptr);
        self.mapped = true;
        self.foreign = c.wlr_foreign_toplevel_handle_v1_create(self.s.foreign);
        var state = c.wlr_ext_foreign_toplevel_handle_v1_state{ .title = if (self.xdg.title != null) self.xdg.title else "", .app_id = if (self.xdg.app_id != null) self.xdg.app_id else "" };
        self.listed = c.wlr_ext_foreign_toplevel_handle_v1_create(self.s.foreign_list, &state);
        if (self.listed) |listed| listed.data = self;
        if (self.foreign) |f| {
            self.hooks.add(&f.events.request_activate, self, &foreignActivate);
            self.hooks.add(&f.events.request_close, self, &foreignClose);
            if (self.output) |o| c.wlr_foreign_toplevel_handle_v1_output_enter(f, o.wlr);
        }
        self.s.updateInhibition();
        title(self, null);
        self.configure();
        c.wlr_scene_node_set_enabled(&self.tree.node, self.workspace == self.s.workspace);
        self.s.focus(self);
    }
    fn unmap(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(View, ptr);
        self.mapped = false;
        if (self.s.grabbed == self) self.s.grabbed = null;
        self.s.updateInhibition();
        // Remove listeners on foreign handles before their signals disappear.
        while (self.hooks.len > 10) {
            self.hooks.len -= 1;
            c.wl_list_remove(&self.hooks.entries[self.hooks.len].listener.link);
        }
        if (self.foreign) |f| c.wlr_foreign_toplevel_handle_v1_destroy(f);
        if (self.listed) |f| c.wlr_ext_foreign_toplevel_handle_v1_destroy(f);
        self.foreign = null;
        self.listed = null;
        if (self.s.cycle_selected == self) self.s.cycle(false, self.s.cycle_app);
        if (self.s.focused == self) {
            self.s.focused = null;
            self.s.refocus();
        }
        if (self.s.cycling) self.s.showSwitcher();
    }
    fn commit(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(View, ptr);
        if (self.xdg.base.*.initial_commit) self.configure();
        if (self.xdg.parent != null and self.mapped) self.configure();
    }
    fn destroy(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(View, ptr);
        defer self.s.a.destroy(self);
        self.alive = false;
        if (self.s.cycle_origin == self) self.s.cycle_origin = null;
        if (self.capture_scene) |scene| c.wlr_scene_node_destroy(&scene.tree.node);
        self.hooks.clear();
        self.capture_hook.clear();
        remove(*View, &self.s.views, self);
    }
    fn title(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(View, ptr);
        const title_text: [*c]const u8 = if (self.xdg.title != null) self.xdg.title else "";
        const app_id: [*c]const u8 = if (self.xdg.app_id != null) self.xdg.app_id else "";
        if (self.foreign) |f| {
            c.wlr_foreign_toplevel_handle_v1_set_title(f, title_text);
            c.wlr_foreign_toplevel_handle_v1_set_app_id(f, app_id);
        }
        if (self.listed) |f| {
            var state = c.wlr_ext_foreign_toplevel_handle_v1_state{ .title = title_text, .app_id = app_id };
            c.wlr_ext_foreign_toplevel_handle_v1_update_state(f, &state);
        }
    }
    fn beginGrab(self: *View, serial: u32, edges: u32) void {
        const s = self.s;
        if (s.locked or self.fullscreen or !self.mapped or !c.wlr_seat_validate_pointer_grab_serial(s.seat, self.xdg.base.*.surface, serial)) return;
        const geo = self.xdg.base.*.geometry;
        s.grabbed = self;
        s.grab_box = .{ .x = self.tree.node.x, .y = self.tree.node.y, .width = geo.width, .height = geo.height };
        s.grab_x = s.cursor.x;
        s.grab_y = s.cursor.y;
        s.resize_edges = edges;
        self.floating_box = s.grab_box;
        self.maximized = false;
        self.tile = .none;
        self.configure();
    }
    fn requestMove(ptr: *anyopaque, data: ?*anyopaque) void {
        cast(View, ptr).beginGrab(cast(c.wlr_xdg_toplevel_move_event, data).serial, 0);
    }
    fn requestResize(ptr: *anyopaque, data: ?*anyopaque) void {
        const e = cast(c.wlr_xdg_toplevel_resize_event, data);
        cast(View, ptr).beginGrab(e.serial, e.edges);
    }
    fn maximize(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(View, ptr);
        self.maximized = self.xdg.requested.maximized;
        if (!self.maximized and self.floating_box == null) if (self.output) |o| {
            self.floating_box = .{ .x = o.usable.x + @divTrunc(o.usable.width, 6), .y = o.usable.y + @divTrunc(o.usable.height, 6), .width = @divTrunc(o.usable.width * 2, 3), .height = @divTrunc(o.usable.height * 2, 3) };
        };
        self.configure();
    }
    fn fullscreenRequest(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(View, ptr);
        self.fullscreen = self.xdg.requested.fullscreen;
        self.configure();
    }
    fn foreignActivate(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(View, ptr);
        self.s.focus(self);
    }
    fn foreignClose(ptr: *anyopaque, _: ?*anyopaque) void {
        c.wlr_xdg_toplevel_send_close(cast(View, ptr).xdg);
    }
    fn captureDestroyed(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(View, ptr);
        self.capture_hook.clear();
        self.capture = null;
    }
};
const Layer = struct {
    s: *Server,
    wlr: *c.wlr_layer_surface_v1,
    scene: *c.wlr_scene_layer_surface_v1,
    target: Target = .{},
    hooks: Hooks = .{},
    fn create(s: *Server, wlr: *c.wlr_layer_surface_v1) void {
        if (wlr.output == null) {
            const output = s.outputAt(s.cursor.x, s.cursor.y) orelse {
                c.wlr_layer_surface_v1_destroy(wlr);
                return;
            };
            wlr.output = output.wlr;
        }
        const self = alloc(Layer, s, .{ .s = s, .wlr = wlr, .scene = c.wlr_scene_layer_surface_v1_create(s.roots[@min(3, wlr.pending.layer)], wlr).? });
        self.target.layer = self;
        self.scene.tree.*.node.data = &self.target;
        wlr.data = self.scene.tree;
        self.hooks.add(&wlr.surface.*.events.commit, self, &commit);
        self.hooks.add(&wlr.surface.*.events.map, self, &map);
        self.hooks.add(&wlr.surface.*.events.unmap, self, &unmap);
        self.hooks.add(&wlr.events.destroy, self, &destroy);
        self.hooks.add(&wlr.events.new_popup, self, &newPopup);
        s.layers.append(s.a, self) catch @panic("layers");
    }
    fn newPopup(ptr: *anyopaque, data: ?*anyopaque) void {
        Popup.create(cast(Layer, ptr).s, cast(c.wlr_xdg_popup, data));
    }
    fn commit(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Layer, ptr);
        c.wlr_scene_node_reparent(&self.scene.tree.*.node, self.s.roots[@min(3, self.wlr.current.layer)]);
        for (self.s.outputs.items) |o| if (o.wlr == self.wlr.output) o.arrange();
    }
    fn map(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Layer, ptr);
        if (!self.s.locked and self.wlr.current.keyboard_interactive != c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE) self.s.keyboardFocus(self.wlr.surface);
    }
    fn unmap(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Layer, ptr);
        if (self.s.seat.keyboard_state.focused_surface == self.wlr.surface) self.s.refocus();
    }
    fn destroy(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Layer, ptr);
        defer self.s.a.destroy(self);
        self.hooks.clear();
        remove(*Layer, &self.s.layers, self);
        for (self.s.outputs.items) |o| if (o.wlr == self.wlr.output) o.arrange();
    }
};
const Decoration = struct {
    wlr: *c.wlr_xdg_toplevel_decoration_v1,
    hooks: Hooks = .{},

    fn create(wlr: *c.wlr_xdg_toplevel_decoration_v1) void {
        const self = heap.create(Decoration) catch @panic("decoration allocation");
        self.* = .{ .wlr = wlr };
        self.hooks.add(&wlr.events.destroy, self, &destroy);
        self.hooks.add(&wlr.events.request_mode, self, &configure);
        self.hooks.add(&wlr.toplevel.*.base.*.surface.*.events.commit, self, &commit);
        configure(self, null);
    }
    fn configure(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Decoration, ptr);
        // Clients such as Chrome create decorations and request a mode before
        // the first surface commit. wlroots cannot schedule a configure yet.
        if (!self.wlr.toplevel.*.base.*.initialized) return;
        _ = c.wlr_xdg_toplevel_decoration_v1_set_mode(self.wlr, c.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
    }
    fn commit(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Decoration, ptr);
        if (self.wlr.toplevel.*.base.*.initial_commit) configure(self, null);
    }
    fn destroy(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Decoration, ptr);
        self.hooks.clear();
        heap.destroy(self);
    }
};

const Popup = struct {
    s: *Server,
    wlr: *c.wlr_xdg_popup,
    tree: *c.wlr_scene_tree,
    hooks: Hooks = .{},
    fn create(s: *Server, wlr: *c.wlr_xdg_popup) void {
        if (wlr.base.*.data != null) return;
        var parent: ?*c.wlr_scene_tree = null;
        if (wlr.parent) |surface| {
            if (c.wlr_xdg_surface_try_from_wlr_surface(surface)) |xdg| {
                if (xdg.*.data) |data| parent = cast(c.wlr_scene_tree, data);
            } else if (c.wlr_layer_surface_v1_try_from_wlr_surface(surface)) |layer| {
                if (layer.*.data) |data| parent = cast(c.wlr_scene_tree, data);
            }
        }
        const tree = parent orelse return;
        const self = alloc(Popup, s, .{ .s = s, .wlr = wlr, .tree = c.wlr_scene_xdg_surface_create(tree, wlr.base).? });
        wlr.base.*.data = self.tree;
        self.hooks.add(&wlr.base.*.surface.*.events.commit, self, &commit);
        self.hooks.add(&wlr.events.destroy, self, &destroy);
    }
    fn commit(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Popup, ptr);
        if (self.wlr.base.*.initial_commit) {
            var box: c.wlr_box = undefined;
            c.wlr_output_layout_get_box(self.s.layout, null, &box);
            var x: c_int = 0;
            var y: c_int = 0;
            if (self.tree.node.parent) |parent| _ = c.wlr_scene_node_coords(&parent.*.node, &x, &y);
            box.x -= x;
            box.y -= y;
            c.wlr_xdg_popup_unconstrain_from_box(self.wlr, &box);
            _ = c.wlr_xdg_surface_schedule_configure(self.wlr.base);
        }
    }
    fn destroy(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Popup, ptr);
        defer self.s.a.destroy(self);
        self.hooks.clear();
    }
};

const Keyboard = struct {
    s: *Server,
    wlr: *c.wlr_keyboard,
    hooks: Hooks = .{},
    consumed: [256]bool = @splat(false),
    fn create(s: *Server, wlr: *c.wlr_keyboard, virtual: bool) void {
        const self = alloc(Keyboard, s, .{ .s = s, .wlr = wlr });
        if (!virtual) {
            const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return;
            defer c.xkb_context_unref(context);
            var names = std.mem.zeroes(c.xkb_rule_names);
            names.options = "caps:none";
            const keymap = c.xkb_keymap_new_from_names(context, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
            defer c.xkb_keymap_unref(keymap);
            if (!c.wlr_keyboard_set_keymap(wlr, keymap)) return;
            c.wlr_keyboard_set_repeat_info(wlr, 25, 600);
        }
        self.hooks.add(&wlr.events.modifiers, self, &modifiers);
        self.hooks.add(&wlr.events.key, self, &key);
        self.hooks.add(&wlr.base.events.destroy, self, &destroy);
        s.keyboards.append(s.a, self) catch @panic("keyboards");
        c.wlr_seat_set_keyboard(s.seat, wlr);
        s.capabilities();
        if (s.locked) {
            if (s.lock) |lock| lock.focus();
        } else if (s.seat.keyboard_state.focused_surface) |surface| s.keyboardFocus(surface);
    }
    fn modifiers(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Keyboard, ptr);
        c.wlr_seat_set_keyboard(self.s.seat, self.wlr);
        c.wlr_seat_keyboard_notify_modifiers(self.s.seat, &self.wlr.modifiers);
        const mods = c.wlr_keyboard_get_modifiers(self.wlr);
        if (self.s.cycling and mods & (c.WLR_MODIFIER_ALT | c.WLR_MODIFIER_LOGO) == 0) self.s.finishCycle(false);
    }
    fn key(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Keyboard, ptr);
        const event = cast(c.wlr_keyboard_key_event, data);
        self.s.activity();
        const pressed = event.state == c.WL_KEYBOARD_KEY_STATE_PRESSED;
        var handled = false;
        if (!self.s.locked and self.wlr.xkb_state != null) {
            const sym = c.xkb_state_key_get_one_sym(self.wlr.xkb_state, event.keycode + 8);
            const mods = c.wlr_keyboard_get_modifiers(self.wlr);
            if (sym == c.XKB_KEY_Super_L) {
                if (pressed) self.s.super_alone = true else {
                    if (self.s.super_alone) launch("overview");
                    self.s.super_alone = false;
                }
                handled = true;
            } else if (pressed) {
                self.s.super_alone = false;
                handled = self.binding(sym, mods);
            }
        }
        if (event.keycode < self.consumed.len) {
            if (pressed) self.consumed[event.keycode] = handled else {
                handled = self.consumed[event.keycode] or handled;
                self.consumed[event.keycode] = false;
            }
        }
        if (!handled) {
            c.wlr_seat_set_keyboard(self.s.seat, self.wlr);
            c.wlr_seat_keyboard_notify_key(self.s.seat, event.time_msec, event.keycode, event.state);
        }
    }
    fn binding(self: *Keyboard, sym: u32, mods: u32) bool {
        const s = self.s;
        const logo = mods & c.WLR_MODIFIER_LOGO != 0;
        const alt = mods & c.WLR_MODIFIER_ALT != 0;
        const shift = mods & c.WLR_MODIFIER_SHIFT != 0;
        if ((logo or alt) and (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab)) {
            s.cycle(shift, false);
            return true;
        }
        if (alt and (sym == c.XKB_KEY_grave or sym == c.XKB_KEY_asciitilde)) {
            s.cycle(shift, true);
            return true;
        }
        if (s.cycling) {
            switch (sym) {
                c.XKB_KEY_Escape => s.finishCycle(true),
                c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => s.finishCycle(false),
                c.XKB_KEY_Down => {
                    s.cycle_app = true;
                    s.showSwitcher();
                },
                c.XKB_KEY_Up => {
                    s.cycle_app = false;
                    s.showSwitcher();
                },
                c.XKB_KEY_Left, c.XKB_KEY_Right => s.cycle(sym == c.XKB_KEY_Left, s.cycle_app),
                else => return false,
            }
            return true;
        }
        if (alt and sym == c.XKB_KEY_F4) {
            if (s.focused) |v| c.wlr_xdg_toplevel_send_close(v.xdg);
            return true;
        }
        if (logo) {
            switch (sym) {
                c.XKB_KEY_Return => launchTerminal(),
                c.XKB_KEY_d, c.XKB_KEY_a => launch("overview"),
                c.XKB_KEY_l => launch("lock --daemonize"),
                c.XKB_KEY_e, c.XKB_KEY_E => {
                    if (!shift) return false;
                    if (s.show_ui) {
                        _ = c.kill(c.getpid(), c.SIGTERM);
                    } else c.wl_display_terminate(s.display);
                },
                c.XKB_KEY_Left, c.XKB_KEY_Right, c.XKB_KEY_Up, c.XKB_KEY_Down => if (s.focused) |v| {
                    v.tile = if (sym == c.XKB_KEY_Left) .left else if (sym == c.XKB_KEY_Right) .right else .none;
                    v.maximized = true;
                    v.configure();
                },
                else => return false,
            }
            return true;
        }
        switch (sym) {
            c.XKB_KEY_XF86AudioRaiseVolume => launch("volume up"),
            c.XKB_KEY_XF86AudioLowerVolume => launch("volume down"),
            c.XKB_KEY_XF86AudioMute => launch("volume mute"),
            c.XKB_KEY_XF86AudioMicMute => launch("microphone mute"),
            c.XKB_KEY_XF86MonBrightnessUp => launch("brightness up"),
            c.XKB_KEY_XF86MonBrightnessDown => launch("brightness down"),
            c.XKB_KEY_Print => launch("screenshot"),
            else => return false,
        }
        return true;
    }
    fn destroy(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Keyboard, ptr);
        defer self.s.a.destroy(self);
        self.hooks.clear();
        remove(*Keyboard, &self.s.keyboards, self);
        self.s.capabilities();
        if (self.s.keyboards.items.len > 0) c.wlr_seat_set_keyboard(self.s.seat, self.s.keyboards.items[0].wlr);
    }
};
// posix_spawn avoids running allocator or GTK code after fork in this threaded process.
fn launch(comptime command: [:0]const u8) void {
    const gtk = @import("desktop-gtk.zig");
    _ = gtk.g_spawn_command_line_async("/proc/self/exe " ++ command, null);
}
fn launchTerminal() void {
    const gtk = @import("desktop-gtk.zig");
    _ = gtk.g_spawn_command_line_async("ghostty", null);
}

const Lock = struct {
    s: *Server,
    wlr: *c.wlr_session_lock_v1,
    hooks: Hooks = .{},
    surfaces: std.ArrayList(*LockSurface) = .empty,
    blanks: std.ArrayList(struct { output: *c.wlr_output, rect: *c.wlr_scene_rect }) = .empty,
    acknowledged: bool = false,
    unlocked: bool = false,
    fn create(s: *Server, wlr: *c.wlr_session_lock_v1) void {
        if (s.lock != null) {
            c.wlr_session_lock_v1_destroy(wlr);
            return;
        }
        if (s.locked) {
            c.wlr_scene_node_destroy(&s.lock_tree.node);
            s.lock_tree = c.wlr_scene_tree_create(&s.scene.tree).?;
        }
        const self = alloc(Lock, s, .{ .s = s, .wlr = wlr });
        s.lock = self;
        s.locked = true;
        s.lock_serial +%= 1;
        s.grabbed = null;
        s.updateInhibition();
        if (s.show_ui) @import("desktop-switcher.zig").publish(.{});
        s.cycling = false;
        s.cycle_origin = null;
        s.cycle_selected = null;
        s.super_alone = false;
        c.wlr_scene_node_set_enabled(&s.lock_tree.node, true);
        c.wlr_scene_node_raise_to_top(&s.lock_tree.node);
        s.keyboardFocus(null);
        c.wlr_seat_pointer_clear_focus(s.seat);
        for (s.outputs.items) |o| self.blankOutput(o);
        self.hooks.add(&wlr.events.new_surface, self, &newSurface);
        self.hooks.add(&wlr.events.unlock, self, &unlock);
        self.hooks.add(&wlr.events.destroy, self, &destroy);
        // Acknowledge only after every enabled output commits an opaque lock frame.
        self.acknowledge();
    }
    fn blankOutput(self: *Lock, output: *Output) void {
        const black = [4]f32{ 0, 0, 0, 1 };
        const rect: *c.wlr_scene_rect = c.wlr_scene_rect_create(self.s.lock_tree, output.box.width, output.box.height, &black).?;
        c.wlr_scene_node_set_position(&rect.node, output.box.x, output.box.y);
        c.wlr_scene_node_lower_to_bottom(&rect.node);
        self.blanks.append(self.s.a, .{ .output = output.wlr, .rect = rect }) catch @panic("lock backgrounds");
    }
    fn acknowledge(self: *Lock) void {
        if (self.acknowledged) return;
        for (self.s.outputs.items) |o| if (o.wlr.enabled and o.lock_serial != self.s.lock_serial) return;
        self.acknowledged = true;
        c.wlr_session_lock_v1_send_locked(self.wlr);
    }
    fn resize(self: *Lock, output: *Output) void {
        for (self.blanks.items) |blank| if (blank.output == output.wlr) {
            c.wlr_scene_rect_set_size(blank.rect, output.box.width, output.box.height);
            c.wlr_scene_node_set_position(&blank.rect.node, output.box.x, output.box.y);
        };
        for (self.surfaces.items) |surface| if (surface.wlr.output == output.wlr) {
            c.wlr_scene_node_set_position(&surface.tree.node, output.box.x, output.box.y);
            _ = c.wlr_session_lock_surface_v1_configure(surface.wlr, @intCast(@max(1, output.box.width)), @intCast(@max(1, output.box.height)));
        };
    }
    fn focus(self: *Lock) void {
        for (self.surfaces.items) |surface| if (surface.wlr.surface.*.mapped) {
            self.s.keyboardFocus(surface.wlr.surface);
            return;
        };
        self.s.keyboardFocus(null);
    }
    fn newSurface(ptr: *anyopaque, data: ?*anyopaque) void {
        const self = cast(Lock, ptr);
        LockSurface.create(self, cast(c.wlr_session_lock_surface_v1, data));
    }
    fn unlock(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Lock, ptr);
        self.unlocked = true;
        self.s.locked = false;
        self.s.updateInhibition();
        c.wlr_scene_node_set_enabled(&self.s.lock_tree.node, false);
        self.s.refocus();
    }
    fn destroy(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Lock, ptr);
        self.hooks.clear();
        defer self.s.a.destroy(self);
        defer self.surfaces.deinit(self.s.a);
        defer self.blanks.deinit(self.s.a);
        self.s.lock = null;
        // A crashed lock leaves the opaque scene and input isolation in place.
        // Only an authenticated unlock may reveal the desktop.
        if (self.unlocked) for (self.blanks.items) |blank| c.wlr_scene_node_destroy(&blank.rect.node);
    }
};
const LockSurface = struct {
    lock: *Lock,
    wlr: *c.wlr_session_lock_surface_v1,
    tree: *c.wlr_scene_tree,
    target: Target = .{ .locked = true },
    hooks: Hooks = .{},
    fn create(lock: *Lock, wlr: *c.wlr_session_lock_surface_v1) void {
        const self = alloc(LockSurface, lock.s, .{ .lock = lock, .wlr = wlr, .tree = c.wlr_scene_subsurface_tree_create(lock.s.lock_tree, wlr.surface).? });
        self.tree.node.data = &self.target;
        for (lock.s.outputs.items) |o| if (o.wlr == wlr.output) {
            c.wlr_scene_node_set_position(&self.tree.node, o.box.x, o.box.y);
            _ = c.wlr_session_lock_surface_v1_configure(wlr, @intCast(o.box.width), @intCast(o.box.height));
        };
        self.hooks.add(&wlr.surface.*.events.map, self, &map);
        self.hooks.add(&wlr.events.destroy, self, &destroy);
        lock.surfaces.append(lock.s.a, self) catch @panic("lock surfaces");
    }
    fn map(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(LockSurface, ptr);
        self.lock.s.keyboardFocus(self.wlr.surface);
    }
    fn destroy(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(LockSurface, ptr);
        defer self.lock.s.a.destroy(self);
        self.hooks.clear();
        remove(*LockSurface, &self.lock.surfaces, self);
        if (self.lock.s.locked) self.lock.focus();
    }
};

const Overview = struct {
    const Interface = extern struct {
        destroy: *const fn (?*c.wl_client, ?*c.wl_resource) callconv(.c) void = &destroy,
        refresh: *const fn (?*c.wl_client, ?*c.wl_resource) callconv(.c) void = &refresh,
        activate: *const fn (?*c.wl_client, ?*c.wl_resource, [*c]const u8) callconv(.c) void = &activate,
        close: *const fn (?*c.wl_client, ?*c.wl_resource, [*c]const u8) callconv(.c) void = &close,
        switch_workspace: *const fn (?*c.wl_client, ?*c.wl_resource, u32) callconv(.c) void = &switchWorkspace,
        move: *const fn (?*c.wl_client, ?*c.wl_resource, [*c]const u8, u32) callconv(.c) void = &move,
    };
    const implementation: Interface = .{};
    fn bind(client: ?*c.wl_client, ptr: ?*anyopaque, _: u32, id: u32) callconv(.c) void {
        const resource = c.wl_resource_create(client, @ptrCast(&p.dotfiles_overview_v1_interface), 1, id) orelse {
            c.wl_client_post_no_memory(client);
            return;
        };
        c.wl_resource_set_implementation(resource, &implementation, ptr, null);
    }
    fn state(resource: ?*c.wl_resource) *Server {
        return cast(Server, c.wl_resource_get_user_data(resource));
    }
    fn find(s: *Server, identifier: [*c]const u8) ?*View {
        if (s.locked) return null;
        for (s.views.items) |v| if (v.listed) |listed| if (same(listed.identifier, identifier)) return v;
        return null;
    }
    fn destroy(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
        c.wl_resource_destroy(resource);
    }
    fn refresh(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
        const s = state(resource);
        if (!s.locked) {
            for (0..4) |index| c.wl_resource_post_event(resource, 0, @as(u32, @intCast(index)), @as([*:0]const u8, switch (index) {
                0 => "1",
                1 => "2",
                2 => "3",
                else => "4",
            }), @as(u32, @intFromBool(index == s.workspace)));
            for (s.views.items) |v| if (v.listed) |listed| {
                const geo = v.xdg.base.*.geometry;
                c.wl_resource_post_event(resource, 1, listed.identifier, v.workspace, v.tree.node.x, v.tree.node.y, geo.width, geo.height, @as(u32, 0));
            };
        }
        c.wl_resource_post_event(resource, 2);
    }
    fn activate(_: ?*c.wl_client, resource: ?*c.wl_resource, id: [*c]const u8) callconv(.c) void {
        const s = state(resource);
        if (find(s, id)) |v| s.focus(v);
    }
    fn close(_: ?*c.wl_client, resource: ?*c.wl_resource, id: [*c]const u8) callconv(.c) void {
        if (find(state(resource), id)) |v| c.wlr_xdg_toplevel_send_close(v.xdg);
    }
    fn switchWorkspace(_: ?*c.wl_client, resource: ?*c.wl_resource, index: u32) callconv(.c) void {
        const s = state(resource);
        s.switchWorkspace(index);
        s.refocus();
    }
    fn move(_: ?*c.wl_client, resource: ?*c.wl_resource, id: [*c]const u8, index: u32) callconv(.c) void {
        const s = state(resource);
        if (index >= 4 or s.locked) return;
        if (find(s, id)) |v| {
            v.workspace = index;
            c.wlr_scene_node_set_enabled(&v.tree.node, v.mapped and index == s.workspace);
            if (s.focused == v and index != s.workspace) s.refocus();
        }
    }
};

const Inhibitor = struct {
    s: *Server,
    wlr: *c.wlr_idle_inhibitor_v1,
    hooks: Hooks = .{},
    fn create(s: *Server, wlr: *c.wlr_idle_inhibitor_v1) void {
        const self = alloc(Inhibitor, s, .{ .s = s, .wlr = wlr });
        self.hooks.add(&wlr.events.destroy, self, &destroy);
        self.hooks.add(&wlr.surface.*.events.map, self, &changed);
        self.hooks.add(&wlr.surface.*.events.unmap, self, &changed);
        s.inhibitors.append(s.a, self) catch @panic("idle inhibitors");
        s.updateInhibition();
    }
    fn changed(ptr: *anyopaque, _: ?*anyopaque) void {
        cast(Inhibitor, ptr).s.updateInhibition();
    }
    fn destroy(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Inhibitor, ptr);
        defer self.s.a.destroy(self);
        self.hooks.clear();
        remove(*Inhibitor, &self.s.inhibitors, self);
        self.s.updateInhibition();
    }
};
const Drag = struct {
    s: *Server,
    hooks: Hooks = .{},
    fn create(s: *Server, wlr: *c.wlr_drag) void {
        const self = alloc(Drag, s, .{ .s = s });
        if (wlr.icon) |icon| {
            s.drag_icon = c.wlr_scene_drag_icon_create(s.roots[3], icon);
            if (s.drag_icon) |tree| c.wlr_scene_node_set_position(&tree.node, @intFromFloat(s.cursor.x), @intFromFloat(s.cursor.y));
            self.hooks.add(&icon.*.events.destroy, self, &iconDestroy);
        }
        self.hooks.add(&wlr.events.destroy, self, &destroy);
    }
    fn iconDestroy(ptr: *anyopaque, _: ?*anyopaque) void {
        cast(Drag, ptr).s.drag_icon = null;
    }
    fn destroy(ptr: *anyopaque, _: ?*anyopaque) void {
        const self = cast(Drag, ptr);
        defer self.s.a.destroy(self);
        self.hooks.clear();
        self.s.drag_icon = null;
    }
};
