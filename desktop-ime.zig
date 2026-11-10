//! Text-input-v3 / input-method-v2 relay owned by the compositor thread.
const std = @import("std");
const c = @import("compositor-abi");
const a = std.heap.page_allocator;
fn cast(comptime T: type, ptr: ?*anyopaque) *T {
    return @ptrCast(@alignCast(ptr.?));
}

pub fn Relay(comptime Hooks: type) type {
    return struct {
        const Self = @This();
        seat: *c.wlr_seat,
        root: *c.wlr_scene_tree,
        owner: *anyopaque,
        position: *const fn (*anyopaque, *c.wlr_surface) c.wlr_box,
        texts: std.ArrayList(*Text) = .empty,
        popups: std.ArrayList(*Popup) = .empty,
        method: ?*c.wlr_input_method_v2 = null,
        method_serial: u32 = 0,
        active: ?*Text = null,
        hooks: Hooks = .{},
        method_hooks: Hooks = .{},

        pub fn init(self: *Self, display: *c.wl_display, seat: *c.wlr_seat, root: *c.wlr_scene_tree, owner: *anyopaque, position: *const fn (*anyopaque, *c.wlr_surface) c.wlr_box) void {
            self.* = .{ .seat = seat, .root = root, .owner = owner, .position = position };
            const texts: *c.wlr_text_input_manager_v3 = c.wlr_text_input_manager_v3_create(display).?;
            const methods: *c.wlr_input_method_manager_v2 = c.wlr_input_method_manager_v2_create(display).?;
            self.hooks.add(&texts.events.new_text_input, self, &newText);
            self.hooks.add(&methods.events.new_input_method, self, &newMethod);
            self.hooks.add(&seat.keyboard_state.events.focus_change, self, &focus);
        }
        pub fn deinit(self: *Self) void {
            self.hooks.clear();
            self.method_hooks.clear();
            self.texts.deinit(a);
            self.popups.deinit(a);
        }
        fn newText(ptr: *anyopaque, data: ?*anyopaque) void {
            const self = cast(Self, ptr);
            const input = cast(c.wlr_text_input_v3, data);
            if (input.seat != self.seat) return;
            const text = a.create(Text) catch @panic("text input");
            text.* = .{ .relay = self, .input = input };
            self.texts.append(a, text) catch @panic("text input");
            text.hooks.add(&input.events.enable, text, &Text.changed);
            text.hooks.add(&input.events.disable, text, &Text.changed);
            text.hooks.add(&input.events.commit, text, &Text.changed);
            text.hooks.add(&input.events.destroy, text, &Text.destroy);
            self.focusText(text);
        }
        fn focusText(self: *Self, text: *Text) void {
            const surface = self.seat.keyboard_state.focused_surface;
            const matches = if (surface) |value| c.wl_resource_get_client(value.*.resource) == c.wl_resource_get_client(text.input.resource) else false;
            if (text.input.focused_surface != surface or !matches) {
                if (text.input.focused_surface != null) c.wlr_text_input_v3_send_leave(text.input);
                if (matches) c.wlr_text_input_v3_send_enter(text.input, surface.?);
            }
        }
        fn focus(ptr: *anyopaque, _: ?*anyopaque) void {
            const self = cast(Self, ptr);
            for (self.texts.items) |text| self.focusText(text);
            self.sync();
        }
        fn sync(self: *Self) void {
            var next: ?*Text = null;
            for (self.texts.items) |text| if (text.input.current_enabled and text.input.focused_surface != null and text.input.focused_surface == self.seat.keyboard_state.focused_surface) {
                next = text;
                break;
            };
            const previous = self.active;
            self.active = next;
            if (self.method) |method| {
                if (previous != next or (next == null and method.active)) {
                    if (method.active) {
                        c.wlr_input_method_v2_send_deactivate(method);
                        self.done();
                    }
                }
                if (next) |text| {
                    if (!method.active) c.wlr_input_method_v2_send_activate(method);
                    const state = text.input.current;
                    c.wlr_input_method_v2_send_surrounding_text(method, state.surrounding.text, state.surrounding.cursor, state.surrounding.anchor);
                    c.wlr_input_method_v2_send_text_change_cause(method, state.text_change_cause);
                    c.wlr_input_method_v2_send_content_type(method, state.content_type.hint, state.content_type.purpose);
                    self.done();
                }
            }
            for (self.popups.items) |popup| popup.update();
        }
        fn done(self: *Self) void {
            c.wlr_input_method_v2_send_done(self.method.?);
            self.method_serial +%= 1;
        }
        fn newMethod(ptr: *anyopaque, data: ?*anyopaque) void {
            const self = cast(Self, ptr);
            const method = cast(c.wlr_input_method_v2, data);
            if (self.method != null or method.seat != self.seat) {
                c.wlr_input_method_v2_send_unavailable(method);
                return;
            }
            self.method = method;
            self.method_serial = 0;
            self.method_hooks.add(&method.events.commit, self, &methodCommit);
            self.method_hooks.add(&method.events.destroy, self, &methodDestroy);
            self.method_hooks.add(&method.events.new_popup_surface, self, &newPopup);
            self.method_hooks.add(&method.events.grab_keyboard, self, &grab);
            self.sync();
        }
        fn methodCommit(ptr: *anyopaque, _: ?*anyopaque) void {
            const self = cast(Self, ptr);
            const text = self.active orelse return;
            const method = self.method orelse return;
            if (method.current_serial != self.method_serial) return;
            if (!method.client_active or !text.input.current_enabled or text.input.focused_surface != self.seat.keyboard_state.focused_surface) return;
            const state = method.current;
            c.wlr_text_input_v3_send_preedit_string(text.input, state.preedit.text, state.preedit.cursor_begin, state.preedit.cursor_end);
            c.wlr_text_input_v3_send_commit_string(text.input, state.commit_text);
            c.wlr_text_input_v3_send_delete_surrounding_text(text.input, state.delete.before_length, state.delete.after_length);
            c.wlr_text_input_v3_send_done(text.input);
        }
        fn methodDestroy(ptr: *anyopaque, _: ?*anyopaque) void {
            const self = cast(Self, ptr);
            self.method_hooks.clear();
            self.method = null;
            if (self.active) |text| {
                c.wlr_text_input_v3_send_preedit_string(text.input, "", 0, 0);
                c.wlr_text_input_v3_send_done(text.input);
            }
        }
        fn grab(ptr: *anyopaque, data: ?*anyopaque) void {
            const self = cast(Self, ptr);
            if (c.wlr_seat_get_keyboard(self.seat)) |keyboard| c.wlr_input_method_keyboard_grab_v2_set_keyboard(cast(c.wlr_input_method_keyboard_grab_v2, data), keyboard);
        }
        pub fn keyboardGrab(self: *Self, keyboard: *c.wlr_keyboard) ?*c.wlr_input_method_keyboard_grab_v2 {
            const method = self.method orelse return null;
            if (self.active == null or !method.active) return null;
            // Keys forwarded by the IME's own virtual keyboard go to the client.
            if (c.wlr_input_device_get_virtual_keyboard(&keyboard.base)) |virtual| if (c.wl_resource_get_client(virtual.*.resource) == c.wl_resource_get_client(method.resource)) return null;
            const value = method.keyboard_grab orelse return null;
            c.wlr_input_method_keyboard_grab_v2_set_keyboard(value, keyboard);
            return value;
        }
        const Text = struct {
            relay: *Self,
            input: *c.wlr_text_input_v3,
            hooks: Hooks = .{},
            fn changed(ptr: *anyopaque, _: ?*anyopaque) void {
                cast(Text, ptr).relay.sync();
            }
            fn destroy(ptr: *anyopaque, _: ?*anyopaque) void {
                const self = cast(Text, ptr);
                const relay = self.relay;
                self.hooks.clear();
                for (relay.texts.items, 0..) |value, i| if (value == self) {
                    _ = relay.texts.orderedRemove(i);
                    break;
                };
                relay.sync();
                a.destroy(self);
            }
        };
        fn newPopup(ptr: *anyopaque, data: ?*anyopaque) void {
            const self = cast(Self, ptr);
            const popup = a.create(Popup) catch @panic("input popup");
            const input = cast(c.wlr_input_popup_surface_v2, data);
            popup.* = .{ .relay = self, .input = input, .tree = c.wlr_scene_subsurface_tree_create(self.root, input.surface).? };
            self.popups.append(a, popup) catch @panic("input popup");
            popup.hooks.add(&input.events.destroy, popup, &Popup.destroy);
            popup.hooks.add(&input.surface.*.events.commit, popup, &Popup.commit);
            popup.update();
        }
        const Popup = struct {
            relay: *Self,
            input: *c.wlr_input_popup_surface_v2,
            tree: *c.wlr_scene_tree,
            hooks: Hooks = .{},
            fn update(self: *Popup) void {
                const text = self.relay.active;
                c.wlr_scene_node_set_enabled(&self.tree.node, text != null);
                if (text) |value| {
                    const surface = value.input.focused_surface orelse return;
                    const box = self.relay.position(self.relay.owner, surface);
                    const rect = value.input.current.cursor_rectangle;
                    const x = std.math.clamp(box.x + rect.x, box.x, @max(box.x, box.x + box.width - self.input.surface.*.current.width));
                    const y = if (rect.y + rect.height + self.input.surface.*.current.height <= box.height) box.y + rect.y + rect.height else @max(box.y, box.y + rect.y - self.input.surface.*.current.height);
                    c.wlr_scene_node_set_position(&self.tree.node, x, y);
                    var relative = rect;
                    relative.x += box.x - x;
                    relative.y += box.y - y;
                    c.wlr_input_popup_surface_v2_send_text_input_rectangle(self.input, &relative);
                }
            }
            fn commit(ptr: *anyopaque, _: ?*anyopaque) void {
                cast(Popup, ptr).update();
            }
            fn destroy(ptr: *anyopaque, _: ?*anyopaque) void {
                const self = cast(Popup, ptr);
                self.hooks.clear();
                for (self.relay.popups.items, 0..) |value, i| if (value == self) {
                    _ = self.relay.popups.orderedRemove(i);
                    break;
                };
                c.wlr_scene_node_destroy(&self.tree.node);
                a.destroy(self);
            }
        };
    };
}
