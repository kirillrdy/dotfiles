//! Icon theme lookup in Zig. GdkPixbuf remains the image decoder for this step.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const a = std.heap.page_allocator;
extern "c" fn access([*:0]const u8, c_int) c_int;
extern "c" fn g_memory_input_stream_new_from_data(*const anyopaque, isize, c.GDestroyNotify) ?*c.GInputStream;
extern "c" fn g_themed_icon_get_type() c.GType;
extern "c" fn g_themed_icon_get_names(*c.GIcon) [*:null]?[*:0]const u8;
extern "c" fn g_file_icon_get_type() c.GType;
extern "c" fn g_file_icon_get_file(*c.GIcon) *c.GFile;
extern "c" fn g_file_get_path(*c.GFile) ?[*:0]u8;
extern "c" fn g_loadable_icon_get_type() c.GType;
extern "c" fn g_loadable_icon_load(*c.GIcon, c_int, ?*?[*:0]u8, ?*c.GCancellable, ?*?*c.GError) ?*c.GInputStream;
extern "c" fn g_icon_new_for_string([*:0]const u8, ?*?*c.GError) ?*c.GIcon;
extern "c" fn gdk_pixbuf_save_to_bufferv(*c.GdkPixbuf, *?[*]u8, *usize, [*:0]const u8, ?*anyopaque, ?*anyopaque, ?*?*c.GError) c.gboolean;

pub const white: c.GdkRGBA = .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 };
pub const foreground: c.GdkRGBA = .{ .red = 250.0 / 255.0, .green = 250.0 / 255.0, .blue = 251.0 / 255.0, .alpha = 1 };
const Directory = struct {
    path: []const u8,
    size: i64 = 0,
    scale: i64 = 1,
    min: ?i64 = null,
    max: ?i64 = null,
    threshold: i64 = 2,
    kind: enum { fixed, scalable, threshold } = .threshold,

    fn distance(self: Directory, size: u32, scale: u32) i64 {
        const requested = @as(i64, size) * scale;
        const low = switch (self.kind) {
            .fixed => self.size,
            .scalable => self.min orelse self.size,
            .threshold => self.size - self.threshold,
        } * self.scale;
        const high = switch (self.kind) {
            .fixed => self.size,
            .scalable => self.max orelse self.size,
            .threshold => self.size + self.threshold,
        } * self.scale;
        return @max(0, @max(low - requested, requested - high));
    }
};
const Theme = struct { name: []const u8, dirs: std.ArrayList(Directory) = .empty, inherits: std.ArrayList([]const u8) = .empty };
const Cached = struct { name: []const u8, size: u32, scale: u32, path: ?[:0]const u8 };

pub const Resolver = struct {
    arena: std.heap.ArenaAllocator,
    scratch: std.heap.ArenaAllocator,
    roots: []const []const u8,
    theme: []const u8,
    themes: std.ArrayList(Theme) = .empty,
    cache: std.ArrayList(Cached) = .empty,
    cache_cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator, roots: []const []const u8, theme: []const u8) !Resolver {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const owned = try alloc.alloc([]const u8, roots.len);
        for (owned, roots) |*out, root| out.* = try alloc.dupe(u8, root);
        return .{ .arena = arena, .scratch = std.heap.ArenaAllocator.init(allocator), .roots = owned, .theme = try alloc.dupe(u8, theme) };
    }
    pub fn deinit(self: *Resolver) void {
        const alloc = self.arena.child_allocator;
        for (self.cache.items) |entry| {
            alloc.free(entry.name);
            if (entry.path) |path| alloc.free(path);
        }
        self.cache.deinit(alloc);
        self.scratch.deinit();
        self.arena.deinit();
    }
    fn themeInfo(self: *Resolver, name: []const u8) !usize {
        for (self.themes.items, 0..) |theme, i| if (std.mem.eql(u8, theme.name, name)) return i;
        const alloc = self.arena.allocator();
        var theme: Theme = .{ .name = try alloc.dupe(u8, name) };
        for (self.roots) |root| {
            const path = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}/index.theme", .{ root, name }, 0);
            const data = read(path) orelse continue;
            defer c.g_free(data.ptr);
            var section: []const u8 = "";
            var lines = std.mem.splitScalar(u8, data, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \r\t");
                if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
                if (line[0] == '[' and line[line.len - 1] == ']') {
                    section = line[1 .. line.len - 1];
                    continue;
                }
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const key = std.mem.trim(u8, line[0..eq], " \t");
                const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
                if (std.mem.eql(u8, section, "Icon Theme")) {
                    if (std.mem.eql(u8, key, "Inherits")) try list(alloc, &theme.inherits, value);
                    if (std.mem.eql(u8, key, "Directories") or std.mem.eql(u8, key, "ScaledDirectories")) {
                        var dirs: std.ArrayList([]const u8) = .empty;
                        try list(alloc, &dirs, value);
                        for (dirs.items) |dir| {
                            var found = false;
                            for (theme.dirs.items) |existing| if (std.mem.eql(u8, existing.path, dir)) {
                                found = true;
                                break;
                            };
                            if (!found) try theme.dirs.append(alloc, .{ .path = dir });
                        }
                    }
                } else for (theme.dirs.items) |*dir| {
                    if (!std.mem.eql(u8, dir.path, section)) continue;
                    if (std.mem.eql(u8, key, "Type")) {
                        dir.kind = if (std.mem.eql(u8, value, "Fixed")) .fixed else if (std.mem.eql(u8, value, "Scalable")) .scalable else .threshold;
                    } else {
                        const n = std.fmt.parseInt(i64, value, 10) catch continue;
                        if (n < 0 or n > 32768) continue;
                        if (std.mem.eql(u8, key, "Size")) dir.size = n;
                        if (std.mem.eql(u8, key, "Scale") and n > 0) dir.scale = n;
                        if (std.mem.eql(u8, key, "MinSize")) dir.min = n;
                        if (std.mem.eql(u8, key, "MaxSize")) dir.max = n;
                        if (std.mem.eql(u8, key, "Threshold")) dir.threshold = n;
                    }
                }
            }
            break;
        }
        // Private hicolor overlays may contain assets without their own index.
        // The system hicolor index, when present, supplies the full directory list.
        if (theme.dirs.items.len == 0 and std.mem.eql(u8, name, "hicolor")) {
            for ([_][]const u8{ "actions", "apps", "categories", "devices", "emblems", "mimetypes", "places", "status" }) |context| {
                try theme.dirs.append(alloc, .{ .path = try std.fmt.allocPrint(alloc, "scalable/{s}", .{context}), .size = 16, .kind = .scalable, .min = 1, .max = 512 });
            }
        }
        try self.themes.append(alloc, theme);
        return self.themes.items.len - 1;
    }
    fn inTheme(self: *Resolver, name: []const u8, size: u32, scale: u32, theme_name: []const u8, visited: *std.ArrayList([]const u8)) anyerror!?[:0]const u8 {
        for (visited.items) |old| if (std.mem.eql(u8, old, theme_name)) return null;
        if (visited.items.len >= 64 or !validName(theme_name)) return null;
        const alloc = self.scratch.allocator();
        const index = try self.themeInfo(theme_name);
        const theme = self.themes.items[index];
        try visited.append(alloc, theme.name);
        var best: ?[:0]const u8 = null;
        var distance: i64 = std.math.maxInt(i64);
        for ([_]bool{ true, false }) |exact| {
            for (theme.dirs.items) |dir| {
                if (dir.size <= 0 or !validRelative(dir.path)) continue;
                const d = dir.distance(size, scale);
                if (exact and (d != 0 or dir.scale != scale)) continue;
                if (!exact and d >= distance) continue;
                for (self.roots) |root| {
                    if (try self.file(root, theme.name, dir.path, name)) |path| {
                        if (exact) return path;
                        best = path;
                        distance = d;
                        break;
                    }
                }
            }
            if (best != null) return best;
        }
        for (theme.inherits.items) |parent| if (try self.inTheme(name, size, scale, parent, visited)) |path| return path;
        return null;
    }
    fn file(self: *Resolver, root: []const u8, theme: []const u8, dir: []const u8, name: []const u8) !?[:0]const u8 {
        var buf: [4096]u8 = undefined;
        for ([_][]const u8{ ".png", ".symbolic.png", ".svg", ".xpm" }) |ext| {
            const path = std.fmt.bufPrintSentinel(&buf, "{s}/{s}/{s}/{s}{s}", .{ root, theme, dir, name, ext }, 0) catch continue;
            if (access(path, 4) == 0) return try self.scratch.allocator().dupeSentinel(u8, path, 0);
        }
        return null;
    }
    /// Results are borrowed until the next lookup. Size is logical. Both hits
    /// and misses are cached, with a fixed entry limit for long-lived sessions.
    pub fn lookup(self: *Resolver, name: []const u8, size: u32, scale: u32) !?[:0]const u8 {
        if (!validName(name) or size == 0 or size > 4096 or scale == 0 or scale > 8) return null;
        for (self.cache.items) |entry| if (entry.size == size and entry.scale == scale and std.mem.eql(u8, entry.name, name)) return entry.path;
        _ = self.scratch.reset(.retain_capacity);
        var visited: std.ArrayList([]const u8) = .empty;
        var path = try self.inTheme(name, size, scale, self.theme, &visited);
        if (path == null) path = try self.inTheme(name, size, scale, "hicolor", &visited);
        if (path == null) for (self.roots) |root| {
            if (try self.file(root, "", "", name)) |found| {
                path = found;
                break;
            }
        };
        const alloc = self.arena.child_allocator;
        const key = try alloc.dupe(u8, name);
        errdefer alloc.free(key);
        const owned_path = if (path) |value| try alloc.dupeSentinel(u8, value, 0) else null;
        errdefer if (owned_path) |value| alloc.free(value);
        const entry: Cached = .{ .name = key, .size = size, .scale = scale, .path = owned_path };
        if (self.cache.items.len < 512) {
            try self.cache.append(alloc, entry);
        } else {
            const old = self.cache.items[self.cache_cursor];
            alloc.free(old.name);
            if (old.path) |value| alloc.free(value);
            self.cache.items[self.cache_cursor] = entry;
            self.cache_cursor = (self.cache_cursor + 1) % self.cache.items.len;
        }
        return owned_path;
    }
};

fn validName(name: []const u8) bool {
    return name.len > 0 and name.len < 256 and std.mem.indexOfAny(u8, name, "/\\\x00") == null and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}
fn validRelative(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}
fn list(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), value: []const u8) !void {
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len != 0) try out.append(allocator, try allocator.dupe(u8, part));
    }
}
fn read(path: [:0]const u8) ?[]u8 {
    var data: [*c]u8 = null;
    var len: usize = 0;
    if (c.g_file_get_contents(path, &data, &len, null) == 0) return null;
    return data[0..len];
}

// UI callers own one GObject reference to each returned image. Lookup metadata
// is shared on the UI thread, while views retain their existing image caches.
var shared: ?Resolver = null;
var theme_settings: ?*c.GSettings = null;
pub fn deinit() void {
    if (shared) |*value| value.deinit();
    shared = null;
    if (theme_settings) |settings| c.g_object_unref(settings);
    theme_settings = null;
}
fn themeChanged(_: ?*c.GSettings, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (shared) |*value| value.deinit();
    shared = null;
}
fn resolver() !*Resolver {
    if (shared) |*value| return value;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    var roots: std.ArrayList([]const u8) = .empty;
    for ([_][:0]const u8{ "DESKTOP_PANEL_ICON_PATH", "DESKTOP_APPS_ICON_PATH" }) |name| if (c.g_getenv(name)) |path| try roots.append(alloc, std.mem.span(path));
    const home = std.mem.span(c.g_get_home_dir());
    try roots.append(alloc, try std.fmt.allocPrint(alloc, "{s}/.icons", .{home}));
    try roots.append(alloc, try std.fmt.allocPrint(alloc, "{s}/icons", .{std.mem.span(c.g_get_user_data_dir())}));
    const dirs = if (c.g_getenv("XDG_DATA_DIRS")) |value| std.mem.span(value) else "/usr/local/share:/usr/share";
    var paths = std.mem.splitScalar(u8, dirs, ':');
    while (paths.next()) |path| if (std.fs.path.isAbsolute(path)) {
        try roots.append(alloc, try std.fmt.allocPrint(alloc, "{s}/icons", .{path}));
    };
    try roots.append(alloc, "/usr/share/pixmaps");
    var theme: []const u8 = "Adwaita";
    if (theme_settings == null) if (c.g_settings_schema_source_get_default()) |source| {
        if (c.g_settings_schema_source_lookup(source, "org.gnome.desktop.interface", 1)) |schema| {
            defer c.g_settings_schema_unref(schema);
            theme_settings = c.g_settings_new_full(schema, null, null);
            _ = c.g_signal_connect_data(theme_settings.?, "changed::icon-theme", @ptrCast(&themeChanged), null, null, 0);
        }
    };
    if (theme_settings) |settings| {
        const name = c.g_settings_get_string(settings, "icon-theme");
        defer c.g_free(name);
        if (validName(std.mem.span(name))) theme = try alloc.dupe(u8, std.mem.span(name));
    }
    shared = try Resolver.init(a, roots.items, theme);
    return &shared.?;
}

pub fn load(name: [:0]const u8, size: u32, scale: u32, tint: ?c.GdkRGBA) ?*c.GdkPixbuf {
    if (size == 0 or size > 4096 or scale == 0 or scale > 8) return null;
    const path = if (std.fs.path.isAbsolute(name)) name else ((resolver() catch return null).lookup(name, size, scale) catch return null) orelse return null;
    const physical: c_int = @intCast(size * scale);
    if (tint) |rgba| {
        if (std.mem.endsWith(u8, path, ".symbolic.png")) return symbolicPng(path, physical, rgba);
        for ([_][]const u8{ "-symbolic.svg", "-symbolic-ltr.svg", "-symbolic-rtl.svg" }) |suffix| {
            if (std.mem.endsWith(u8, path, suffix)) return symbolic(path, physical, rgba);
        }
    }
    return c.gdk_pixbuf_new_from_file_at_scale(path, physical, physical, 1, null);
}

pub fn loadThemed(icon: ?*c.GIcon, size: c_int, fallback: ?*c.GdkPixbuf, fallback_name: ?[*c]const u8) ?*c.GdkPixbuf {
    if (size <= 0) return null;
    if (icon) |value| {
        if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(value)), g_themed_icon_get_type()) != 0) {
            const names = g_themed_icon_get_names(value);
            var i: usize = 0;
            while (names[i]) |name| : (i += 1) if (load(std.mem.span(name), @intCast(size), 1, foreground)) |image| return image;
        } else if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(value)), g_file_icon_get_type()) != 0) {
            if (g_file_get_path(g_file_icon_get_file(value))) |path| {
                defer c.g_free(path);
                if (load(std.mem.span(path), @intCast(size), 1, foreground)) |image| return image;
            }
        }
        if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(value)), g_loadable_icon_get_type()) != 0) {
            if (g_loadable_icon_load(value, size, null, null, null)) |stream| {
                defer c.g_object_unref(stream);
                if (c.gdk_pixbuf_new_from_stream_at_scale(stream, size, size, 1, null, null)) |image| return image;
            }
        }
    }
    if (fallback) |image| return @ptrCast(@alignCast(c.g_object_ref(image)));
    if (fallback_name) |name| return load(std.mem.span(name), @intCast(size), 1, null);
    return null;
}

fn symbolic(path: [:0]const u8, size: c_int, tint: c.GdkRGBA) ?*c.GdkPixbuf {
    const data = read(path) orelse return null;
    defer c.g_free(data.ptr);
    const original = c.gdk_pixbuf_new_from_file(path, null) orelse return null;
    defer c.g_object_unref(original);
    const encoded = a.alloc(u8, std.base64.standard.Encoder.calcSize(data.len)) catch return null;
    defer a.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, data);
    var css: std.Io.Writer.Allocating = .init(a);
    defer css.deinit();
    const rgba = [3]u32{ @intFromFloat(@round(std.math.clamp(tint.red, 0, 1) * 255)), @intFromFloat(@round(std.math.clamp(tint.green, 0, 1) * 255)), @intFromFloat(@round(std.math.clamp(tint.blue, 0, 1) * 255)) };
    const colors = [_][3]u32{ rgba, .{ 78, 154, 6 }, .{ 245, 121, 62 }, .{ 204, 0, 0 } };
    for ([_][]const u8{ "rect,circle,path,p", ".success", ".warning", ".error" }, colors) |selector, rgb| {
        css.writer.print("{s}{{fill:rgb({d},{d},{d})!important;stroke:none!important}}", .{ selector, rgb[0], rgb[1], rgb[2] }) catch return null;
    }
    for ([_][]const u8{ "rect.stroke,circle.stroke,path.stroke,p.stroke", ".success.stroke", ".warning.stroke", ".error.stroke" }, colors) |selector, rgb| {
        css.writer.print("{s}{{fill:none!important;stroke:rgb({d},{d},{d})!important}}", .{ selector, rgb[0], rgb[1], rgb[2] }) catch return null;
    }
    const svg = std.fmt.allocPrint(a, "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xi=\"http://www.w3.org/2001/XInclude\" width=\"{d}\" height=\"{d}\"><style>{s}</style><g opacity=\"{d}\"><xi:include href=\"data:text/xml;base64,{s}\"/></g></svg>", .{ c.gdk_pixbuf_get_width(original), c.gdk_pixbuf_get_height(original), css.written(), std.math.clamp(tint.alpha, 0, 1), encoded }) catch return null;
    defer a.free(svg);
    const stream = g_memory_input_stream_new_from_data(svg.ptr, @intCast(svg.len), null) orelse return null;
    defer c.g_object_unref(stream);
    return c.gdk_pixbuf_new_from_stream_at_scale(stream, size, size, 1, null, null);
}

fn symbolicPng(path: [:0]const u8, size: c_int, tint: c.GdkRGBA) ?*c.GdkPixbuf {
    const image = c.gdk_pixbuf_new_from_file_at_scale(path, size, size, 1, null) orelse return null;
    const view = c.__zig.pixbufImage(image);
    if (view.format != .rgba) {
        c.g_object_unref(image);
        return null;
    }
    const colors = [_][3]u32{
        .{ @intFromFloat(std.math.clamp(tint.red, 0, 1) * 255), @intFromFloat(std.math.clamp(tint.green, 0, 1) * 255), @intFromFloat(std.math.clamp(tint.blue, 0, 1) * 255) },
        .{ 77, 153, 5 },
        .{ 244, 120, 61 },
        .{ 203, 0, 0 },
    };
    const alpha: u32 = @intFromFloat(std.math.clamp(tint.alpha, 0, 1) * 255);
    const pixels = c.gdk_pixbuf_get_pixels(image);
    for (0..view.height) |y| for (0..view.width) |x| {
        const pixel = pixels[y * view.stride + x * 4 ..][0..4];
        const weights = [4]u32{ 255 -| (@as(u32, pixel[0]) + pixel[1] + pixel[2]), pixel[0], pixel[1], pixel[2] };
        var rgb: [3]u32 = @splat(0);
        for (colors, weights) |color, weight| for (&rgb, color) |*out, channel| {
            out.* += channel * weight;
        };
        for (pixel[0..3], rgb) |*out, channel| out.* = if (pixel[3] == 0) 0 else @intCast(@min(255, channel / 255));
        pixel[3] = @intCast(@as(u32, pixel[3]) * alpha / 255);
    };
    return image;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator) };
    }
    fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }
    fn put(self: *Fixture, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| try self.tmp.dir.createDirPath(std.testing.io, dir);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }
};

test "theme lookup respects root overrides, size, scale and inheritance cycles" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const index =
        "[Icon Theme]\nName=Child\nInherits=Parent\nDirectories=16/apps,48/apps,scalable/status\nScaledDirectories=16@2/apps\n" ++
        "[16/apps]\nSize=16\nType=Fixed\n[48/apps]\nSize=48\nType=Fixed\n" ++
        "[scalable/status]\nSize=16\nType=Scalable\nMinSize=8\nMaxSize=64\n" ++
        "[16@2/apps]\nSize=16\nScale=2\nType=Fixed\n";
    try fixture.put("system/Child/index.theme", index);
    try fixture.put("system/Child/16/apps/app.svg", "");
    try fixture.put("user/Child/16/apps/app.svg", "");
    try fixture.put("system/Child/48/apps/app.png", "");
    try fixture.put("system/Child/16@2/apps/app.svg", "");
    try fixture.put("system/Child/scalable/status/state-symbolic.svg", "");
    try fixture.put("system/Parent/index.theme", "[Icon Theme]\nInherits=Child\nDirectories=32/apps\n[32/apps]\nSize=32\nType=Fixed\n");
    try fixture.put("system/Parent/32/apps/app.svg", "");
    try fixture.put("system/Parent/32/apps/inherited.svg", "");
    try fixture.put("system/hicolor/scalable/status/fallback.svg", "");
    const user = try std.fmt.allocPrint(std.testing.allocator, "{s}/user", .{fixture.root});
    defer std.testing.allocator.free(user);
    const system = try std.fmt.allocPrint(std.testing.allocator, "{s}/system", .{fixture.root});
    defer std.testing.allocator.free(system);
    var theme = try Resolver.init(std.testing.allocator, &.{ user, system }, "Child");
    defer theme.deinit();
    try std.testing.expect(std.mem.endsWith(u8, (try theme.lookup("app", 16, 1)).?, "user/Child/16/apps/app.svg"));
    try std.testing.expect(std.mem.endsWith(u8, (try theme.lookup("app", 16, 2)).?, "Child/16@2/apps/app.svg"));
    // A closer match in a parent must not override an icon in the child theme.
    try std.testing.expect(std.mem.endsWith(u8, (try theme.lookup("app", 32, 1)).?, "Child/16@2/apps/app.svg"));
    try std.testing.expect(std.mem.endsWith(u8, (try theme.lookup("app", 40, 1)).?, "Child/48/apps/app.png"));
    try std.testing.expect(std.mem.endsWith(u8, (try theme.lookup("state-symbolic", 24, 2)).?, "scalable/status/state-symbolic.svg"));
    try std.testing.expect(std.mem.endsWith(u8, (try theme.lookup("inherited", 32, 1)).?, "Parent/32/apps/inherited.svg"));
    try std.testing.expect(std.mem.endsWith(u8, (try theme.lookup("fallback", 32, 1)).?, "hicolor/scalable/status/fallback.svg"));
    try std.testing.expectEqual(@as(?[:0]const u8, null), try theme.lookup("missing", 16, 1));
    const cached = theme.cache.items.len;
    _ = try theme.lookup("missing", 16, 1);
    try std.testing.expectEqual(cached, theme.cache.items.len);
    try std.testing.expectEqual(@as(?[:0]const u8, null), try theme.lookup("../escape", 16, 1));
    for (0..520) |i| {
        var buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "missing-{d}", .{i});
        try std.testing.expectEqual(@as(?[:0]const u8, null), try theme.lookup(name, 16, 1));
    }
    try std.testing.expectEqual(@as(usize, 512), theme.cache.items.len);
    try std.testing.expect(std.mem.endsWith(u8, (try theme.lookup("app", 16, 1)).?, "user/Child/16/apps/app.svg"));
}

test "Zig symbolic icon rendering matches GTK palette, opacity and scale without a display" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.put("Test/index.theme", "[Icon Theme]\nName=Test\nDirectories=scalable/status\n[scalable/status]\nSize=16\nType=Scalable\nMinSize=1\nMaxSize=64\n");
    try fixture.put("Test/scalable/status/probe-symbolic.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\"><path d=\"M0 0h4v16H0z\"/><path class=\"success\" d=\"M4 0h4v16H4z\"/><path class=\"warning\" d=\"M8 0h4v16H8z\"/><path class=\"error\" d=\"M12 0h4v16h-4z\"/></svg>");
    const theme = c.gtk_icon_theme_new();
    defer c.g_object_unref(theme);
    c.gtk_icon_theme_append_search_path(theme, fixture.root);
    c.gtk_icon_theme_set_custom_theme(theme, "Test");
    var lookup = try Resolver.init(std.testing.allocator, &.{fixture.root}, "Test");
    defer lookup.deinit();
    const tint: c.GdkRGBA = .{ .red = 0.3, .green = 0.6, .blue = 0.9, .alpha = 0.7 };
    for ([_]u32{ 1, 2 }) |scale| {
        const size: c_int = @intCast(16 * scale);
        const info = c.gtk_icon_theme_lookup_icon(theme, "probe-symbolic", size, c.GTK_ICON_LOOKUP_FORCE_SIZE) orelse return error.ReferenceIconMissing;
        defer c.g_object_unref(info);
        const expected = c.gtk_icon_info_load_symbolic(info, &tint, null, null, null, null, null) orelse return error.ReferenceIconDecode;
        defer c.g_object_unref(expected);
        const actual = symbolic((try lookup.lookup("probe-symbolic", 16, scale)).?, size, tint) orelse return error.IconDecode;
        defer c.g_object_unref(actual);
        const e = c.__zig.pixbufImage(expected);
        const v = c.__zig.pixbufImage(actual);
        try std.testing.expectEqual(e.width, v.width);
        try std.testing.expectEqual(e.height, v.height);
        for (0..v.height) |y| try std.testing.expectEqualSlices(u8, e.pixels[y * e.stride ..][0 .. e.width * 4], v.pixels[y * v.stride ..][0 .. v.width * 4]);
    }
}

test "symbolic PNG palettes and file GIcons use the existing decoder without GTK lookup" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const image = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 1, 8, 4, 1) orelse return error.IconAllocation;
    defer c.g_object_unref(image);
    @memcpy(c.gdk_pixbuf_get_pixels(image)[0..16], &[_]u8{ 0, 0, 0, 255, 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 128 });
    var data: ?[*]u8 = null;
    var len: usize = 0;
    try std.testing.expect(gdk_pixbuf_save_to_bufferv(image, &data, &len, "png", null, null, null) != 0);
    defer c.g_free(data.?);
    try fixture.put("palette-symbolic.symbolic.png", data.?[0..len]);
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/palette-symbolic.symbolic.png", .{fixture.root}, 0);
    defer std.testing.allocator.free(path);
    const tinted = load(path, 4, 1, .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.5 }) orelse return error.IconDecode;
    defer c.g_object_unref(tinted);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 127, 77, 153, 5, 127, 244, 120, 61, 127, 203, 0, 0, 63 }, c.gdk_pixbuf_get_pixels(tinted)[0..16]);
    const icon = g_icon_new_for_string(path, null) orelse return error.InvalidIcon;
    defer c.g_object_unref(icon);
    const loaded = loadThemed(icon, 8, null, null) orelse return error.IconDecode;
    defer c.g_object_unref(loaded);
    try std.testing.expectEqual(@as(c_int, 8), c.gdk_pixbuf_get_width(loaded));
    try std.testing.expectEqual(@as(c_int, 2), c.gdk_pixbuf_get_height(loaded));
}

test "native icon lookup renders installed Adwaita symbols at both output scales" {
    try @import("desktop-runtime.zig").setup(std.testing.allocator);
    deinit();
    defer deinit();
    for ([_][:0]const u8{ "view-app-grid-symbolic", "view-refresh-symbolic", "audio-volume-high-symbolic", "battery-level-50-symbolic", "dark-mode-symbolic" }) |name| {
        for ([_]u32{ 1, 2 }) |scale| {
            const image = load(name, 16, scale, white) orelse return error.InstalledIconMissing;
            defer c.g_object_unref(image);
            try std.testing.expectEqual(@as(c_int, @intCast(16 * scale)), c.gdk_pixbuf_get_width(image));
            const pixels = c.__zig.pixbufImage(image);
            var visible = false;
            for (0..pixels.height) |y| for (0..pixels.width) |x| {
                if (pixels.format == .rgba and pixels.pixels[y * pixels.stride + x * 4 + 3] != 0) visible = true;
            };
            try std.testing.expect(visible);
        }
    }
}
