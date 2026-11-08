//! GNOME Files picker geometry and rendering, independent of portal requests.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const form = @import("desktop-form.zig");
const raster = @import("desktop-raster.zig");
extern fn g_date_time_new_from_unix_local(i64) ?*c.GDateTime;
extern fn g_memory_input_stream_new_from_data(*const anyopaque, isize, c.GDestroyNotify) ?*c.GInputStream;
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
pub const Rect = form.Rect;
pub const Row = struct { item: usize, entry: usize, ordinal: usize, icon: [:0]const u8, size: u64, modified: u64, directory: bool };
pub const Place = struct { item: usize, path: [:0]const u8, icon: [:0]const u8 };
const Icon = struct { name: [:0]const u8, size: u32, image: *c.GdkPixbuf };

pub const View = struct {
    path: usize = 0,
    location: usize = 0,
    back: usize = 0,
    forward: usize = 0,
    up: usize = 0,
    search: usize = 0,
    query: usize = 0,
    folder_search: usize = 0,
    toggle_view: usize = 0,
    menu: usize = 0,
    options: usize = 0,
    hidden: usize = 0,
    cancel: usize = 0,
    accept: usize = 0,
    message: usize = 0,
    filter: ?usize = null,
    name: ?usize = null,
    extras: []const usize = &.{},
    rows: []const Row = &.{},
    places: []const Place = &.{},
    folder: [:0]const u8 = "",
    count: usize = 0,
    selected_count: usize = 0,
    selected_size: u64 = 0,
    selected_name: [:0]const u8 = "",
    selected_directory: bool = false,
    loading: bool = true,
    grid: bool = true,
    editing_location: bool = false,
    searching: bool = false,
    menu_open: bool = false,
    options_open: bool = false,
    offset: f64 = 0,
    width: f64 = 900,
    height: f64 = 600,
    sidebar: f64 = 180,
    columns: usize = 4,
    icons: std.ArrayList(Icon) = .empty,
    icon_scale: u32 = 0,

    pub const header_height = 46;
    pub const footer_height = 64;
    pub const cell_width = 168;
    pub const cell_height = 138;

    pub fn deinit(self: *View) void {
        self.clearIcons();
        self.icons.deinit(a);
    }
    fn clearIcons(self: *View) void {
        for (self.icons.items) |cached| c.g_object_unref(cached.image);
        self.icons.clearRetainingCapacity();
    }
    pub fn rowHeight(self: *const View) f64 {
        return if (self.grid) cell_height else 52;
    }
    pub fn contentTop(self: *const View) f64 {
        return header_height + @as(f64, if (self.grid) 16 else 42);
    }
    pub fn first(self: *const View) usize {
        return @as(usize, @intFromFloat(@floor(self.offset / self.rowHeight()))) * self.columns;
    }
    pub fn maxOffset(self: *const View) f64 {
        const lines = std.math.divCeil(usize, self.count, self.columns) catch unreachable;
        return @max(0, @as(f64, @floatFromInt(lines)) * self.rowHeight() + self.contentTop() - header_height + 16 - (self.height - header_height - footer_height));
    }
    pub fn reveal(self: *View, ordinal: usize) void {
        const top = @as(f64, @floatFromInt(ordinal / self.columns)) * self.rowHeight();
        const viewport = self.height - self.contentTop() - footer_height - 16;
        if (top < self.offset) self.offset = top;
        if (top + self.rowHeight() > self.offset + viewport) self.offset = top + self.rowHeight() - viewport;
        self.offset = std.math.clamp(self.offset, 0, self.maxOffset());
    }
    fn place(ui: *form.Form, id: usize, rect: Rect) void {
        const item = ui.get(id);
        item.visible = true;
        item.bounds = rect;
        if (item.entry) |entry| entry.rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
    }
    pub fn layout(self: *View, ui: *form.Form) void {
        self.width = @floatFromInt(ui.width);
        self.height = @floatFromInt(@max(348, c.gtk_widget_get_allocated_height(ui.canvas)));
        self.sidebar = std.math.clamp(@floor(self.width * 0.2), 180, 240);
        self.columns = if (self.grid) @max(1, @as(usize, @intFromFloat(@floor((self.width - self.sidebar - 32) / cell_width)))) else 1;
        self.offset = std.math.clamp(self.offset, 0, self.maxOffset());
        ui.height = @intFromFloat(self.height);
        for (ui.items.items) |item| {
            item.visible = false;
            item.pinned = false;
            item.clip = null;
        }
        place(ui, self.search, .{ .x = 6, .y = 6, .width = 34, .height = 34 });
        place(ui, self.back, .{ .x = self.sidebar + 6, .y = 6, .width = 34, .height = 34 });
        place(ui, self.forward, .{ .x = self.sidebar + 46, .y = 6, .width = 34, .height = 34 });
        const location = Rect{ .x = self.sidebar + 86, .y = 6, .width = self.width - self.sidebar - 236, .height = 34 };
        place(ui, if (self.searching) self.query else if (self.editing_location) self.path else self.location, location);
        place(ui, self.folder_search, .{ .x = self.width - 142, .y = 6, .width = 34, .height = 34 });
        place(ui, self.toggle_view, .{ .x = self.width - 102, .y = 6, .width = 34, .height = 34 });
        place(ui, self.menu, .{ .x = self.width - 68, .y = 6, .width = 28, .height = 34 });
        place(ui, self.cancel, .{ .x = self.width - 35, .y = 11, .width = 24, .height = 24 });
        for (self.places, 0..) |p, i| place(ui, p.item, .{ .x = 8, .y = 52 + @as(f64, @floatFromInt(i * 38)), .width = self.sidebar - 16, .height = 36 });
        const clip_top = if (self.grid) @as(f64, header_height) else self.contentTop();
        const content: Rect = .{ .x = self.sidebar, .y = clip_top, .width = self.width - self.sidebar, .height = self.height - clip_top - footer_height };
        for (self.rows) |row| {
            const y = self.contentTop() + @as(f64, @floatFromInt(row.ordinal / self.columns)) * self.rowHeight() - self.offset;
            place(ui, row.item, .{
                .x = self.sidebar + (if (self.grid) @as(f64, 15) else 16) + (if (self.grid) @as(f64, @floatFromInt(row.ordinal % self.columns)) * cell_width else 0),
                .y = y,
                .width = if (self.grid) cell_width else content.width - 32,
                .height = self.rowHeight(),
            });
            ui.get(row.item).clip = content;
        }
        const bottom = self.height - footer_height;
        place(ui, self.accept, .{ .x = self.width - 115, .y = bottom + 8, .width = 103, .height = 44 });
        place(ui, self.options, .{ .x = self.width - 164, .y = bottom + 14, .width = 36, .height = 36 });
        if (self.filter) |id| place(ui, id, .{ .x = self.sidebar + 16, .y = bottom + 14, .width = @min(200, content.width * 0.3), .height = 36 });
        if (self.name) |id| place(ui, id, .{ .x = self.sidebar + 24 + (if (self.filter != null) @as(f64, 200) else 0), .y = bottom + 14, .width = @max(100, content.width - (if (self.filter != null) @as(f64, 410) else 210)), .height = 36 });
        if (self.menu_open) place(ui, self.hidden, .{ .x = self.width - 246, .y = 54, .width = 224, .height = 40 });
        if (self.options_open) {
            const top = bottom - @as(f64, @floatFromInt(self.extras.len * 44)) - 16;
            for (self.extras, 0..) |id, i| place(ui, id, .{ .x = self.width - 344, .y = top + @as(f64, @floatFromInt(i * 44)), .width = 320, .height = 40 });
        }
        c.gtk_widget_set_no_show_all(ui.footer, 1);
        c.gtk_widget_hide(ui.footer);
        c.gtk_widget_set_size_request(ui.canvas, 580, 348);
    }

    fn fill(canvas: raster.Canvas, rect: Rect, rgb: u32, radius: f64) void {
        canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height }, .radius = radius } }}, raster.Color.rgb(rgb, 1));
    }
    fn label(ui: *form.Form, canvas: raster.Canvas, value: [:0]const u8, rect: Rect, bold: bool, centered: bool, tint: u32) !void {
        const mask = try ui.renderer.renderLayout(a, value, .{ .font = if (bold) "Adwaita Sans Bold" else "Adwaita Sans", .size = 14.666 * canvas.scale, .dpi = 96 * canvas.scale, .width = @intFromFloat(@max(1, rect.width) * canvas.scale), .ellipsize = true, .lines = 1, .origin = .top, .alignment = if (centered) .center else .left });
        defer mask.deinit(a);
        mask.paint(canvas, rect.x, rect.y + (rect.height - @as(f64, @floatFromInt(mask.logical_height)) / canvas.scale) / 2, raster.Color.rgb(tint, 1));
    }
    fn icon(self: *View, canvas: raster.Canvas, name: [:0]const u8, x: f64, y: f64, size: u32) !void {
        const physical: u32 = @intFromFloat(@as(f64, @floatFromInt(size)) * canvas.scale);
        var pixbuf: ?*c.GdkPixbuf = null;
        for (self.icons.items) |entry| if (entry.size == physical and std.mem.eql(u8, entry.name, name)) {
            pixbuf = entry.image;
            break;
        };
        if (pixbuf == null) {
            const asset: ?[]const u8 = if (std.mem.eql(u8, name, "file-chooser-options-symbolic")) @embedFile("desktop-icons/file-chooser-options-symbolic.svg") else if (std.mem.eql(u8, name, "file-chooser-folder-search-symbolic")) @embedFile("desktop-icons/file-chooser-folder-search-symbolic.svg") else null;
            if (asset) |svg| {
                const stream = g_memory_input_stream_new_from_data(svg.ptr, @intCast(svg.len), null) orelse return error.IconAllocation;
                defer c.g_object_unref(stream);
                pixbuf = c.gdk_pixbuf_new_from_stream_at_scale(stream, @intCast(physical), @intCast(physical), 1, null, null);
            } else {
                const info = c.gtk_icon_theme_lookup_icon(c.gtk_icon_theme_get_default(), name, @intCast(physical), c.GTK_ICON_LOOKUP_FORCE_SIZE) orelse return;
                defer c.g_object_unref(info);
                const symbolic = std.mem.endsWith(u8, name, "-symbolic");
                const foreground: c.GdkRGBA = .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 };
                pixbuf = if (symbolic) c.gtk_icon_info_load_symbolic(info, &foreground, null, null, null, null, null) else c.gtk_icon_info_load_icon(info, null);
            }
            if (pixbuf) |image| self.icons.append(a, .{ .name = name, .size = physical, .image = image }) catch |err| {
                c.g_object_unref(image);
                return err;
            };
        }
        if (pixbuf) |image| c.__zig.blitPixbuf(canvas, image, .{ .x = x, .y = y, .width = @floatFromInt(size), .height = @floatFromInt(size) });
    }
    fn button(self: *View, ui: *form.Form, canvas: raster.Canvas, id: usize, name: [:0]const u8) !void {
        const item = ui.get(id);
        if (!item.visible) return;
        if (ui.hover == id or ui.pressed == id) fill(canvas, item.bounds, if (ui.pressed == id) 0x47474b else 0x333336, 6);
        const x = item.bounds.x + (item.bounds.width - 16) / 2;
        const y = item.bounds.y + (item.bounds.height - 16) / 2;
        try self.icon(canvas, name, x, y, 16);
        if (!item.enabled) canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = item.bounds.x, .y = item.bounds.y, .width = item.bounds.width, .height = item.bounds.height }, .radius = 6 } }}, raster.Color.rgb(0x1d1d20, 0.7));
    }
    fn dropdown(self: *View, ui: *form.Form, canvas: raster.Canvas, id: usize) !void {
        const field = ui.get(id);
        if (!field.visible) return;
        if (ui.hover == id or ui.expanded == id) fill(canvas, field.bounds, 0x333336, 6);
        const value = if (field.selected) |index| field.options.items[index].label else "All Files";
        try label(ui, canvas, value, .{ .x = field.bounds.x + 10, .y = field.bounds.y, .width = field.bounds.width - 36, .height = field.bounds.height }, false, false, 0xffffff);
        try self.icon(canvas, "pan-down-symbolic", field.bounds.x + field.bounds.width - 26, field.bounds.y + 10, 16);
    }
    pub fn paint(self: *View, ui: *form.Form, target: raster.Buffer, scale: u32) !void {
        if (self.icon_scale != scale) {
            self.clearIcons();
            self.icon_scale = scale;
        }
        self.layout(ui);
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        @memset(target.pixels, 0xff1d1d20);
        for (self.rows) |row| {
            const field = ui.get(row.item);
            const r = field.bounds;
            if (r.y + r.height < header_height or r.y > self.height - footer_height) continue;
            const inset: f64 = if (self.grid) 12 else 8;
            if (field.checked or ui.hover == row.item) fill(canvas, .{ .x = r.x + inset, .y = r.y + (if (self.grid) @as(f64, 2) else 4), .width = r.width - inset * 2, .height = r.height - (if (self.grid) @as(f64, 6) else 8) }, if (field.checked) 0x3d3d3f else 0x303034, if (self.grid) @as(f64, 12) else 8);
            const icon_size: u32 = if (self.grid) 96 else 32;
            try self.icon(canvas, row.icon, r.x + (if (self.grid) (r.width - 96) / 2 else 14), r.y + (if (self.grid) @as(f64, 8) else 10), icon_size);
            const text_rect = Rect{ .x = r.x + (if (self.grid) @as(f64, 12) else 52), .y = r.y + (if (self.grid) @as(f64, 104) else 0), .width = if (self.grid) r.width - 24 else @max(1, r.width - 270), .height = if (self.grid) 30 else 52 };
            if (field.title_mask == null) field.title_mask = try ui.renderer.renderLayout(a, field.title, .{ .font = "Adwaita Sans", .size = 14.666 * canvas.scale, .dpi = 96 * canvas.scale, .width = @intFromFloat(text_rect.width * canvas.scale), .ellipsize = true, .lines = 1, .alignment = if (self.grid) .center else .left, .origin = .top });
            const mask = field.title_mask.?;
            mask.paint(canvas, text_rect.x, text_rect.y + (text_rect.height - @as(f64, @floatFromInt(mask.logical_height)) / canvas.scale) / 2, raster.Color.rgb(0xffffff, 1));
            if (!self.grid) {
                var size_buffer: [48]u8 = undefined;
                const size = if (row.directory) @as([:0]const u8, "—") else if (row.size < 1000) try std.fmt.bufPrintSentinel(&size_buffer, "{d} bytes", .{row.size}, 0) else if (row.size < 1000000) try std.fmt.bufPrintSentinel(&size_buffer, "{d:.1} kB", .{@as(f64, @floatFromInt(row.size)) / 1000}, 0) else try std.fmt.bufPrintSentinel(&size_buffer, "{d:.1} MB", .{@as(f64, @floatFromInt(row.size)) / 1000000}, 0);
                try label(ui, canvas, size, .{ .x = self.width - 198, .y = r.y, .width = 70, .height = r.height }, false, false, 0x9a9a9e);
                if (row.modified > 0 and row.modified <= std.math.maxInt(i64)) {
                    const date = g_date_time_new_from_unix_local(@intCast(row.modified));
                    if (date) |value| {
                        defer c.g_date_time_unref(value);
                        const now = c.g_date_time_new_now_local();
                        defer if (now != null) c.g_date_time_unref(now);
                        const today = now != null and c.g_date_time_get_year(value) == c.g_date_time_get_year(now) and c.g_date_time_get_day_of_year(value) == c.g_date_time_get_day_of_year(now);
                        const formatted = c.g_date_time_format(value, if (today) "Today, %H:%M" else "%b %e, %Y");
                        if (formatted != null) {
                            defer c.g_free(formatted);
                            try label(ui, canvas, std.mem.span(formatted), .{ .x = self.width - 123, .y = r.y, .width = 108, .height = r.height }, false, false, 0x9a9a9e);
                        }
                    }
                }
            }
            if (ui.focus == row.item) canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = r.x + inset + 1, .y = r.y + (if (self.grid) @as(f64, 3) else 5), .width = r.width - inset * 2 - 2, .height = r.height - (if (self.grid) @as(f64, 8) else 10) }, .radius = if (self.grid) 11 else 7, .width = 2 } }}, raster.Color.rgb(0x868688, 1));
        }
        // Toolbar/sidebar/footer cover partial rows while the file view scrolls.
        fill(canvas, .{ .x = 0, .y = 0, .width = self.sidebar - 1, .height = self.height }, 0x2e2e32, 0);
        fill(canvas, .{ .x = self.sidebar, .y = 0, .width = self.width - self.sidebar, .height = header_height }, 0x1d1d20, 0);
        fill(canvas, .{ .x = self.sidebar, .y = self.height - footer_height, .width = self.width - self.sidebar, .height = footer_height }, 0x1d1d20, 0);
        if (!self.grid) {
            fill(canvas, .{ .x = self.sidebar, .y = header_height, .width = self.width - self.sidebar, .height = 42 }, 0x1d1d20, 0);
            try label(ui, canvas, "Name", .{ .x = self.sidebar + 30, .y = header_height, .width = 80, .height = 28 }, true, false, 0x9a9a9e);
            try label(ui, canvas, "Size", .{ .x = self.width - 198, .y = header_height, .width = 70, .height = 28 }, true, false, 0x9a9a9e);
            try label(ui, canvas, "Modified", .{ .x = self.width - 123, .y = header_height, .width = 108, .height = 28 }, true, false, 0x9a9a9e);
        }
        try label(ui, canvas, ui.title, .{ .x = 39, .y = 6, .width = self.sidebar - 80, .height = 34 }, true, true, 0xffffff);
        for (self.places) |p| {
            const field = ui.get(p.item);
            if (std.mem.eql(u8, self.folder, p.path) or ui.hover == p.item) fill(canvas, field.bounds, if (std.mem.eql(u8, self.folder, p.path)) 0x47474b else 0x3b3b3f, 6);
            try self.icon(canvas, p.icon, 20, field.bounds.y + 10, 16);
            try label(ui, canvas, field.title, .{ .x = 44, .y = field.bounds.y, .width = self.sidebar - 56, .height = field.bounds.height }, false, false, 0xffffff);
        }
        try self.button(ui, canvas, self.search, "edit-find-symbolic");
        try self.button(ui, canvas, self.back, "go-previous-symbolic");
        try self.button(ui, canvas, self.forward, "go-next-symbolic");
        try self.button(ui, canvas, self.folder_search, "file-chooser-folder-search-symbolic");
        try self.button(ui, canvas, self.toggle_view, if (self.grid) "view-list-symbolic" else "view-grid-symbolic");
        try self.button(ui, canvas, self.menu, "pan-down-symbolic");
        fill(canvas, ui.get(self.cancel).bounds, 0x333336, 12);
        try self.button(ui, canvas, self.cancel, "window-close-symbolic");
        if (self.searching) {
            try ui.get(self.query).entry.?.paint(target, scale);
        } else if (self.editing_location) {
            try ui.get(self.path).entry.?.paint(target, scale);
        } else {
            const r = ui.get(self.location).bounds;
            fill(canvas, r, 0x333336, 9);
            try self.icon(canvas, "drive-harddisk-symbolic", r.x + 12, r.y + 9, 16);
            const home = std.mem.span(c.g_get_home_dir());
            var path = std.mem.tokenizeScalar(u8, self.folder, '/');
            var x = r.x + 34;
            const root_label: [:0]const u8 = if (std.mem.startsWith(u8, self.folder, home)) "Home" else "NixOS";
            try label(ui, canvas, root_label, .{ .x = x, .y = r.y, .width = 54, .height = r.height }, true, false, 0xb4b4b7);
            x += 54;
            while (path.next()) |part| {
                if (std.mem.startsWith(u8, self.folder, home) and path.index <= home.len) continue;
                if (x + 50 > r.x + r.width - 24) break;
                try label(ui, canvas, "/", .{ .x = x, .y = r.y, .width = 16, .height = r.height }, false, false, 0x9a9a9e);
                x += 20;
                const segment = try a.dupeSentinel(u8, part, 0);
                defer a.free(segment);
                const mask = try ui.renderer.renderLayout(a, segment, .{ .font = "Adwaita Sans Bold", .size = 14.666 * canvas.scale, .dpi = 96 * canvas.scale, .width = @intFromFloat(@max(1, r.x + r.width - 24 - x) * canvas.scale), .ellipsize = true, .origin = .top });
                defer mask.deinit(a);
                mask.paint(canvas, x, r.y + (r.height - @as(f64, @floatFromInt(mask.logical_height)) / canvas.scale) / 2, raster.Color.rgb(if (path.index >= self.folder.len) @as(u32, 0xffffff) else 0xb4b4b7, 1));
                x += @as(f64, @floatFromInt(mask.logical_width)) / canvas.scale + 20;
            }
            try self.icon(canvas, "view-more-symbolic", r.x + r.width - 24, r.y + 9, 16);
        }
        const accept = ui.get(self.accept);
        fill(canvas, accept.bounds, if (accept.enabled) (if (ui.hover == self.accept) @as(u32, 0x4b91e6) else 0x3584e4) else 0x295082, 22);
        try label(ui, canvas, accept.title, accept.bounds, true, true, if (accept.enabled) @as(u32, 0xffffff) else 0x909093);
        try self.button(ui, canvas, self.options, "file-chooser-options-symbolic");
        if (self.filter) |id| try self.dropdown(ui, canvas, id);
        if (self.name) |id| try ui.get(id).entry.?.paint(target, scale);
        if (self.loading or self.count == 0) {
            const value: [:0]const u8 = if (self.loading) "Loading…" else "Folder is Empty";
            try self.icon(canvas, "folder-symbolic", self.sidebar + (self.width - self.sidebar) / 2 - 32, self.height / 2 - 72, 64);
            try label(ui, canvas, value, .{ .x = self.sidebar + 24, .y = self.height / 2 + 8, .width = self.width - self.sidebar - 48, .height = 30 }, true, true, 0x9a9a9e);
        }
        if (self.maxOffset() > 0) {
            const track = self.height - header_height - footer_height;
            const thumb = @max(32, track * track / (track + self.maxOffset()));
            fill(canvas, .{ .x = self.width - 7, .y = header_height + (track - thumb) * self.offset / self.maxOffset(), .width = 4, .height = thumb }, 0x626266, 2);
        }
        if (self.selected_count > 0) {
            const value = if (self.selected_count == 1)
                if (self.selected_directory) try std.fmt.allocPrintSentinel(a, "“{s}” selected", .{self.selected_name}, 0) else try std.fmt.allocPrintSentinel(a, "“{s}” selected ({d} bytes)", .{ self.selected_name, self.selected_size }, 0)
            else
                try std.fmt.allocPrintSentinel(a, "{d} items selected ({d} bytes)", .{ self.selected_count, self.selected_size }, 0);
            defer a.free(value);
            const mask = try ui.renderer.renderLayout(a, value, .{ .font = "Adwaita Sans", .size = 14.666 * canvas.scale, .dpi = 96 * canvas.scale, .width = @intFromFloat(@max(1, self.width - self.sidebar - 48) * canvas.scale), .ellipsize = true, .lines = 1, .origin = .top });
            defer mask.deinit(a);
            const width = @min(self.width - self.sidebar - 24, @as(f64, @floatFromInt(mask.logical_width)) / canvas.scale + 20);
            const rect = Rect{ .x = self.width - width - 4, .y = self.height - footer_height - 36, .width = width, .height = 28 };
            fill(canvas, rect, 0x333336, 14);
            mask.paint(canvas, rect.x + 10, rect.y + (28 - @as(f64, @floatFromInt(mask.logical_height)) / canvas.scale) / 2, raster.Color.rgb(0xffffff, 1));
        }
        const message = ui.get(self.message).title;
        if (message.len > 0 and !self.loading) {
            const r = Rect{ .x = self.sidebar + 24, .y = self.height - footer_height - 54, .width = self.width - self.sidebar - 48, .height = 40 };
            fill(canvas, r, 0x3b3b40, 9);
            try label(ui, canvas, message, .{ .x = r.x + 12, .y = r.y, .width = r.width - 24, .height = 40 }, false, false, 0xffffff);
        }
        if (self.menu_open) {
            const r = ui.get(self.hidden).bounds;
            fill(canvas, .{ .x = r.x - 8, .y = r.y - 8, .width = r.width + 16, .height = 56 }, 0x38383c, 12);
            try self.paintOption(ui, canvas, self.hidden);
        }
        if (self.options_open and self.extras.len > 0) {
            const r = ui.get(self.extras[0]).bounds;
            fill(canvas, .{ .x = r.x - 8, .y = r.y - 8, .width = r.width + 16, .height = @as(f64, @floatFromInt(self.extras.len * 44)) + 12 }, 0x38383c, 12);
            for (self.extras) |id| try self.paintOption(ui, canvas, id);
        }
        if (ui.expanded) |id| {
            const field = ui.get(id);
            const top = ui.optionTop(field);
            fill(canvas, .{ .x = field.bounds.x, .y = top - 6, .width = field.bounds.width, .height = @as(f64, @floatFromInt(field.options.items.len * 36)) + 12 }, 0x38383c, 10);
            for (field.options.items, 0..) |opt, i| {
                const r = Rect{ .x = field.bounds.x + 6, .y = top + @as(f64, @floatFromInt(i * 36)), .width = field.bounds.width - 12, .height = 36 };
                if (ui.option_cursor == i) fill(canvas, r, 0x4b4b50, 6);
                try label(ui, canvas, opt.label, .{ .x = r.x + 8, .y = r.y, .width = r.width - 16, .height = 36 }, false, false, 0xffffff);
            }
        }
    }
    fn paintOption(self: *View, ui: *form.Form, canvas: raster.Canvas, id: usize) !void {
        const field = ui.get(id);
        if (ui.hover == id) fill(canvas, field.bounds, 0x4b4b50, 6);
        if (field.kind == .choice) return self.dropdown(ui, canvas, id);
        try label(ui, canvas, field.title, .{ .x = field.bounds.x + 12, .y = field.bounds.y, .width = field.bounds.width - 44, .height = field.bounds.height }, false, false, 0xffffff);
        if (field.checked) try self.icon(canvas, "object-select-symbolic", field.bounds.x + field.bounds.width - 28, field.bounds.y + 12, 16);
    }
};
