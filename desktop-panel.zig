//! Native Wayland layer-shell panel hosting native pixel views.
const std = @import("std");
const c = @import("desktop-glib.zig");
const p = @import("desktop-protocols.zig");
const raster = @import("desktop-raster.zig");
const wire = @import("desktop-surface.zig");
const widgets = @import("desktop-widgets.zig");
const allocator = std.heap.page_allocator;

pub const Config = struct {
    height: u16 = 32,
    left: []const widgets.Options = &.{},
    center: []const widgets.Options = &.{},
    right: []const widgets.Options = &.{},
};

const Slot = struct {
    module: *widgets.Module,
    on_click: ?[:0]const u8 = null,
    x: f64 = 0,
    width: f64 = 0,
};

fn spawnAsync(command: [:0]const u8) void {
    if (command.len == 0) return;
    var err: ?*c.GError = null;
    _ = c.g_spawn_command_line_async(command.ptr, &err);
    c.g_clear_error(&err);
}

const Panel = struct {
    app: *App,
    output: *wire.Output,
    surface: *wire.Surface,
    slots: std.ArrayList(Slot) = .empty,
    left_count: usize = 0,
    center_count: usize = 0,
    pixels: std.ArrayList(u32) = .empty,
    hovered_index: ?usize = null,
    tooltip_surface: ?*wire.Surface = null,
    tooltip_timer: c.guint = 0,
    tooltip_text: [:0]const u8 = "",
    tooltip_owned: bool = false,
    tooltip_label: widgets.native.Label = .{},
    tooltip_x: i32 = 0,
    tooltip_width: u32 = 0,
    tooltip_height: u32 = 0,

    fn appendGroup(self: *Panel, options: []const widgets.Options) usize {
        for (options) |option| {
            const module = widgets.init(option, self.app.devices, &onModuleRedraw, self);
            self.slots.append(allocator, .{ .module = module, .on_click = option.on_click }) catch @panic("out of memory");
        }
        return options.len;
    }

    fn create(app: *App, output: *wire.Output) !*Panel {
        const self = try allocator.create(Panel);
        errdefer allocator.destroy(self);
        self.* = .{ .app = app, .output = output, .surface = undefined };
        const surface = try wire.Surface.createPixels(output, .{
            .namespace = "desktop-panel",
            .layer = 2,
            .anchors = wire.top | wire.left | wire.right,
            .width = 0,
            .height = app.config.height,
            .exclusive_zone = @intCast(app.config.height),
            .interactive = true,
            .keyboard = .on_demand,
            .cursor = .arrow,
            .clear_buffer = false,
        }, &draw, self);
        errdefer surface.destroy();
        surface.input = .{ .motion = &motion, .leave = &leave, .button = &button };
        self.surface = surface;
        self.left_count = self.appendGroup(app.config.left);
        self.center_count = self.appendGroup(app.config.center);
        _ = self.appendGroup(app.config.right);
        self.applyOverview(app.overview_active, app.workspace_count, app.workspace_active);
        try surface.show();
        return self;
    }

    fn onModuleRedraw(data: ?*anyopaque) void {
        const self: *Panel = @ptrCast(@alignCast(data));
        self.surface.redraw();
    }

    fn layout(self: *Panel, scale: u32) void {
        const height: f64 = @floatFromInt(self.app.config.height);
        for (self.slots.items) |*slot| {
            slot.module.view.prepare(scale, height) catch |err| std.log.err("panel layout: {s}", .{@errorName(err)});
            slot.width = @floatFromInt(slot.module.view.width);
        }
        const panel_width: f64 = @floatFromInt(self.surface.width);
        var x: f64 = 0;
        for (self.slots.items[0..self.left_count]) |*slot| {
            slot.x = x;
            x += slot.width;
        }
        const center_end = self.left_count + self.center_count;
        var center_width: f64 = 0;
        for (self.slots.items[self.left_count..center_end]) |slot| center_width += slot.width;
        var cx = @floor((panel_width - center_width) / 2);
        for (self.slots.items[self.left_count..center_end]) |*slot| {
            slot.x = cx;
            cx += slot.width;
        }
        var right_width: f64 = 0;
        for (self.slots.items[center_end..]) |slot| right_width += slot.width;
        var rx = panel_width - right_width;
        for (self.slots.items[center_end..]) |*slot| {
            slot.x = rx;
            rx += slot.width;
        }
    }

    fn draw(data: ?*anyopaque, target: wire.Pixels) void {
        const self: *Panel = @ptrCast(@alignCast(data));
        const factor = self.surface.buffer_scale;
        @memset(target.pixels, if (self.app.overview_active) 0 else 0xff000000);
        self.layout(factor);
        for (self.slots.items) |slot| {
            const mod_w = slot.module.view.width * factor;
            const mod_h = target.height;
            const needed = mod_w * mod_h;
            if (needed == 0) continue;
            if (self.pixels.items.len < needed) self.pixels.resize(allocator, needed) catch continue;
            const buf = self.pixels.items[0..needed];
            slot.module.view.paint(.{ .pixels = buf, .width = mod_w, .height = mod_h });
            const dest_x: i32 = @intFromFloat(@round(slot.x * @as(f64, @floatFromInt(factor))));
            for (0..mod_h) |py| {
                const row_off = py * target.width;
                const src_off = py * mod_w;
                for (0..mod_w) |px| {
                    const dx = dest_x + @as(i32, @intCast(px));
                    if (dx < 0 or dx >= @as(i32, @intCast(target.width))) continue;
                    const src = buf[src_off + px];
                    if (src >> 24 == 0) continue;
                    target.pixels[row_off + @as(usize, @intCast(dx))] = if (self.app.overview_active) src else (0xff000000 | (src & 0x00ffffff));
                }
            }
        }
    }

    fn slotAt(self: *const Panel, x: f64) ?usize {
        for (self.slots.items, 0..) |slot, i| {
            if (x >= slot.x and x < slot.x + slot.width) return i;
        }
        return null;
    }

    fn clearTooltipText(self: *Panel) void {
        if (self.tooltip_owned) allocator.free(self.tooltip_text);
        self.tooltip_text = "";
        self.tooltip_owned = false;
    }

    fn hideTooltip(self: *Panel) void {
        if (self.tooltip_timer != 0) _ = c.g_source_remove(self.tooltip_timer);
        self.tooltip_timer = 0;
        if (self.tooltip_surface) |surface| surface.hide();
        self.clearTooltipText();
    }

    fn tooltipFor(self: *const Panel, index: usize, x: f64, y: f64) [:0]const u8 {
        if (self.codexVisible()) return "";
        const slot = self.slots.items[index];
        const m = slot.module;
        const local_x = x - slot.x;
        if (m.monitors != 0) {
            const gi: usize = @intFromFloat(@max(0, local_x - 18) / 118);
            if (gi < 3) return m.view.graphs[gi].tooltip.value;
        } else if (!m.view.codex) {
            if (m.view.hit(local_x, y)) |item_idx| {
                if (m.view.items[item_idx].tooltip.value.len != 0) return m.view.items[item_idx].tooltip.value;
            }
        }
        return if (m.tooltip != null) std.mem.span(m.tooltip) else "";
    }

    fn onTooltipTimer(data: c.gpointer) callconv(.c) c.gboolean {
        const self: *Panel = @ptrCast(@alignCast(data));
        self.tooltip_timer = 0;
        self.showTooltip() catch {};
        return 0;
    }

    fn showTooltip(self: *Panel) !void {
        if (self.tooltip_text.len == 0 or self.codexVisible()) return;
        const scale = self.output.scale;
        self.tooltip_label.set(self.tooltip_text);
        try self.tooltip_label.prepare(&self.slots.items[0].module.view.renderer, scale, 13.333, false, null, false);
        if (self.tooltip_label.width() > 480) try self.tooltip_label.prepare(&self.slots.items[0].module.view.renderer, scale, 13.333, false, 480, false);
        const w: u32 = @max(1, @as(u32, @intFromFloat(@ceil(self.tooltip_label.width() + 16))));
        const h: u32 = @max(1, @as(u32, @intFromFloat(@ceil(self.tooltip_label.height() + 16))));
        self.tooltip_width = w;
        self.tooltip_height = h;
        const x = std.math.clamp(self.tooltip_x - @as(i32, @intCast(w / 2)), 4, @max(4, self.output.width() - @as(i32, @intCast(w)) - 4));
        const y: i32 = @as(i32, @intCast(self.app.config.height)) + 4;
        if (self.tooltip_surface == null) {
            self.tooltip_surface = try wire.Surface.createPixels(self.output, .{
                .namespace = "desktop-tooltip",
                .layer = 3,
                .anchors = wire.top | wire.left,
                .width = w,
                .height = h,
                .top_margin = y,
                .left_margin = x,
                .interactive = false,
                .keyboard = .none,
            }, &drawTooltip, self);
        }
        self.tooltip_surface.?.setLayout(w, h, y, x);
        try self.tooltip_surface.?.show();
    }

    fn drawTooltip(data: ?*anyopaque, target: wire.Pixels) void {
        const self: *Panel = @ptrCast(@alignCast(data));
        const factor = self.tooltip_surface.?.buffer_scale;
        self.tooltip_label.prepare(&self.slots.items[0].module.view.renderer, factor, 13.333, false, self.tooltip_label.limit, false) catch return;
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(factor) };
        const w: f64 = @as(f64, @floatFromInt(target.width)) / canvas.scale;
        const h: f64 = @as(f64, @floatFromInt(target.height)) / canvas.scale;
        const rect: raster.Rect = .{ .x = 0.5, .y = 0.5, .width = @max(0, w - 1), .height = @max(0, h - 1) };
        canvas.draw(&.{.{ .rounded_rect = .{ .rect = rect, .radius = 12 } }}, .{ .red = 54.0 / 255.0, .green = 54.0 / 255.0, .blue = 58.0 / 255.0 });
        canvas.draw(&.{.{ .rounded_stroke = .{ .rect = rect, .radius = 12 } }}, .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.15 });
        self.tooltip_label.paint(target, 8, 8, .{ .red = 1, .green = 1, .blue = 1 });
    }

    fn motion(data: ?*anyopaque, _: *wire.Surface, x: f64, y: f64) void {
        const self: *Panel = @ptrCast(@alignCast(data));
        const hit = self.slotAt(x);
        if (self.hovered_index != hit) {
            if (self.hovered_index) |old| self.slots.items[old].module.view.hovered = false;
            self.hovered_index = hit;
            if (hit) |new| self.slots.items[new].module.view.hovered = true;
            self.surface.redraw();
        }
        if (hit) |idx| {
            const text = self.tooltipFor(idx, x, y);
            if (text.len == 0) {
                self.hideTooltip();
            } else if (!std.mem.eql(u8, self.tooltip_text, text)) {
                self.hideTooltip();
                self.tooltip_text = allocator.dupeSentinel(u8, text, 0) catch return;
                self.tooltip_owned = true;
                self.tooltip_x = @intFromFloat(@round(x));
                self.tooltip_timer = c.g_timeout_add(500, &onTooltipTimer, self);
            } else {
                self.tooltip_x = @intFromFloat(@round(x));
            }
        } else {
            self.hideTooltip();
        }
    }

    fn leave(data: ?*anyopaque, _: *wire.Surface) void {
        const self: *Panel = @ptrCast(@alignCast(data));
        if (self.hovered_index) |old| {
            self.slots.items[old].module.view.hovered = false;
            self.hovered_index = null;
            self.surface.redraw();
        }
        self.hideTooltip();
    }

    fn button(data: ?*anyopaque, _: *wire.Surface, button_id: u32, pressed: bool, x: f64, y: f64) void {
        const self: *Panel = @ptrCast(@alignCast(data));
        if (button_id != 272 or !pressed) return;
        self.hideTooltip();
        const idx = self.slotAt(x) orelse return;
        const slot = self.slots.items[idx];
        const m = slot.module;
        const global_x = self.output.x + @as(i32, @intFromFloat(@round(slot.x + slot.width / 2)));
        const global_y = self.output.y + @as(i32, @intCast(self.app.config.height));
        if (slot.on_click) |command| {
            spawnAsync(command);
            return;
        }
        if (m.status != 0) {
            const controls = m.quick orelse return;
            if (controls.popup.visible) {
                controls.hide();
            } else {
                controls.show(global_x, global_y) catch |err| std.log.err("quick settings popup: {s}", .{@errorName(err)});
            }
            return;
        }
        if (m.date_controls) |controls| {
            if (controls.popup.visible) {
                controls.hide();
            } else {
                widgets.historyOpen(m, true);
                controls.reset();
                controls.show(global_x, global_y) catch |err| std.log.err("date popup: {s}", .{@errorName(err)});
            }
            return;
        }
        if (m.view.codex) {
            self.toggleCodex(m, global_x, global_y) catch |err| std.log.err("codex popup: {s}", .{@errorName(err)});
            return;
        }
        if (m.view.hit(x - slot.x, y)) |item_idx| spawnAsync(m.view.items[item_idx].command.value);
    }

    fn codexVisible(self: *const Panel) bool {
        for (self.slots.items) |slot| if (slot.module.codex_menu) |menu| {
            if (menu.popup.visible) return true;
        };
        return false;
    }
    fn hideCodex(self: *Panel) void {
        for (self.slots.items) |slot| if (slot.module.codex_menu) |menu| menu.hide();
    }
    fn toggleCodex(self: *Panel, m: *widgets.Module, global_x: i32, global_y: i32) !void {
        if (self.codexVisible()) {
            self.hideCodex();
            return;
        }
        self.hideTooltip();
        try m.codex_menu.?.show(global_x, global_y);
    }

    fn applyOverview(self: *Panel, active: bool, workspace_count: u8, workspace_active: u8) void {
        for (self.slots.items) |slot| widgets.setOverviewState(slot.module, active, workspace_count, workspace_active);
        self.surface.redraw();
    }

    fn destroy(self: *Panel) void {
        self.hideTooltip();
        self.hideCodex();
        if (self.tooltip_surface) |surface| surface.destroy();
        self.tooltip_label.deinit();
        for (self.slots.items) |slot| widgets.deinit(slot.module);
        self.slots.deinit(allocator);
        self.pixels.deinit(allocator);
        self.surface.destroy();
        allocator.destroy(self);
    }
};

const App = struct {
    devices: *@import("desktop-devices.zig").Service,
    config: Config,
    client: *wire.Client = undefined,
    panels: std.ArrayList(*Panel) = .empty,
    revision: u64 = 0,
    overview_active: bool = false,
    workspace_count: u8 = 2,
    workspace_active: u8 = 0,
    pending_count: u8 = 0,
    pending_active: u8 = 0,
    registry: ?*c.wl_registry = null,
    overview: ?*p.dotfiles_overview_v1 = null,

    fn syncPanels(self: *App) void {
        for (self.panels.items) |panel| panel.applyOverview(self.overview_active, self.workspace_count, self.workspace_active);
    }

    fn connectOverview(self: *App) void {
        const registry = c.wl_display_get_registry(self.client.display) orelse return;
        self.registry = registry;
        _ = c.wl_registry_add_listener(registry, &registry_listener, self);
        _ = c.wl_display_roundtrip(self.client.display);
    }

    fn deinitOverview(self: *App) void {
        if (self.overview) |overview| p.dotfiles_overview_v1_destroy(overview);
        if (self.registry) |registry| c.wl_registry_destroy(registry);
        self.overview = null;
        self.registry = null;
    }

    fn onGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        if (self.overview == null and version >= 2 and std.mem.eql(u8, std.mem.span(interface), "dotfiles_overview_v1")) {
            self.overview = @ptrCast(c.wl_registry_bind(registry, name, &p.dotfiles_overview_v1_interface, 2));
            if (self.overview) |overview| _ = p.dotfiles_overview_v1_add_listener(overview, &overview_listener, self);
        }
    }

    fn onGlobalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

    fn onWorkspace(data: ?*anyopaque, _: ?*p.dotfiles_overview_v1, index: u32, _: [*c]const u8, active: u32) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        self.pending_count = @max(self.pending_count, @as(u8, @intCast(@min(index + 1, 16))));
        if (active != 0) self.pending_active = @intCast(@min(index, 15));
    }

    fn onWindow(_: ?*anyopaque, _: ?*p.dotfiles_overview_v1, _: [*c]const u8, _: u32, _: i32, _: i32, _: i32, _: i32, _: u32) callconv(.c) void {}

    fn onDone(data: ?*anyopaque, _: ?*p.dotfiles_overview_v1) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        if (self.pending_count > 0) {
            self.workspace_count = self.pending_count;
            self.workspace_active = @min(self.pending_active, self.workspace_count - 1);
            self.pending_count = 0;
            self.pending_active = 0;
            self.syncPanels();
        }
    }

    fn onOverview(data: ?*anyopaque, _: ?*p.dotfiles_overview_v1, active: u32) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data));
        const next = active != 0;
        if (self.overview_active == next) return;
        self.overview_active = next;
        self.syncPanels();
    }

    const registry_listener: c.wl_registry_listener = .{ .global = &onGlobal, .global_remove = &onGlobalRemove };
    const overview_listener: p.dotfiles_overview_v1_listener = .{
        .workspace = &onWorkspace,
        .window = &onWindow,
        .done = &onDone,
        .overview = &onOverview,
    };

    fn onOutputAdded(data: ?*anyopaque, output: *wire.Output) void {
        const self: *App = @ptrCast(@alignCast(data));
        const panel = Panel.create(self, output) catch |err| {
            std.log.err("panel create: {s}", .{@errorName(err)});
            return;
        };
        self.panels.append(allocator, panel) catch @panic("out of memory");
        self.revision +%= 1;
    }

    fn onOutputRemoved(data: ?*anyopaque, output: *wire.Output) void {
        const self: *App = @ptrCast(@alignCast(data));
        for (self.panels.items, 0..) |panel, i| {
            if (panel.output == output) {
                _ = self.panels.orderedRemove(i);
                panel.destroy();
                self.revision +%= 1;
                return;
            }
        }
    }

    fn onOutputChanged(data: ?*anyopaque, output: *wire.Output) void {
        const self: *App = @ptrCast(@alignCast(data));
        for (self.panels.items) |panel| {
            if (panel.output == output) panel.surface.redraw();
        }
    }
};

/// Owns native Wayland panel surfaces; the session owns the GLib event loop.
pub const Service = struct {
    arena: std.heap.ArenaAllocator,
    app: App,

    pub fn create(config_path: [:0]const u8, devices: *@import("desktop-devices.zig").Service) !*Service {
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var contents: [*c]u8 = null;
        var length: c.gsize = 0;
        if (c.g_file_get_contents(config_path, &contents, &length, null) == 0) return error.InvalidConfig;
        defer c.g_free(contents);
        const parsed = try std.json.parseFromSlice(Config, arena.allocator(), contents[0..length], .{});
        if (parsed.value.height == 0) return error.InvalidConfig;
        self.* = .{ .arena = arena, .app = .{ .config = parsed.value, .devices = devices } };
        const client = try wire.Client.createInteractive(.{
            .added = &App.onOutputAdded,
            .removed = &App.onOutputRemoved,
            .changed = &App.onOutputChanged,
        }, &self.app);
        errdefer client.destroy();
        if (client.shell == null) return error.LayerShellUnavailable;
        self.app.client = client;
        self.app.connectOverview();
        try client.start();
        return self;
    }

    pub fn revision(self: *Service) u64 {
        return self.app.revision;
    }

    pub fn update(self: *Service, source: []const u8, value: @import("desktop-panel-data.zig").Update) void {
        for (self.app.panels.items) |panel| for (panel.slots.items) |slot| {
            if (std.mem.eql(u8, std.mem.span(slot.module.source), source)) widgets.update(slot.module, value);
        };
    }

    pub fn destroy(self: *Service) void {
        self.app.deinitOverview();
        while (self.app.panels.items.len > 0) {
            const panel = self.app.panels.pop().?;
            panel.destroy();
        }
        self.app.panels.deinit(allocator);
        self.app.client.destroy();
        self.arena.deinit();
        allocator.destroy(self);
    }
};
