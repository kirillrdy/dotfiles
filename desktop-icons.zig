//! Icon theme lookup in Zig. Images decode through desktop-decode.zig.
const std = @import("std");
const c = @import("desktop-glib.zig");
const decode = @import("desktop-decode.zig");
const files = @import("desktop-paths.zig");
const Image = decode.Image;
const Color = @import("desktop-raster.zig").Color;
extern "c" fn access([*:0]const u8, c_int) c_int;
extern "c" fn g_themed_icon_get_type() c.GType;
extern "c" fn g_themed_icon_get_names(*c.GIcon) [*:null]?[*:0]const u8;
extern "c" fn g_file_icon_get_type() c.GType;
extern "c" fn g_file_icon_get_file(*c.GIcon) *c.GFile;
extern "c" fn g_file_get_path(*c.GFile) ?[*:0]u8;
extern "c" fn g_loadable_icon_get_type() c.GType;
extern "c" fn g_loadable_icon_load(*c.GIcon, c_int, ?*?[*:0]u8, ?*c.GCancellable, ?*?*c.GError) ?*c.GInputStream;
extern "c" fn g_icon_new_for_string([*:0]const u8, ?*?*c.GError) ?*c.GIcon;

pub const white: Color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 };
pub const foreground: Color = .{ .red = 250.0 / 255.0, .green = 250.0 / 255.0, .blue = 251.0 / 255.0, .alpha = 1 };
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

    /// Prefer smaller distance; on ties, prefer downscaling over upscaling and matching scale.
    fn betterThan(self: Directory, candidate_d: i64, current: ?Directory, current_d: i64, size: u32, scale: u32) bool {
        const best = current orelse return true;
        if (candidate_d != current_d) return candidate_d < current_d;
        const requested = @as(i64, size) * scale;
        const cand_size = self.size * self.scale;
        const best_size = best.size * best.scale;
        const cand_downscale = cand_size >= requested;
        const best_downscale = best_size >= requested;
        if (cand_downscale != best_downscale) return cand_downscale;
        if (cand_size != best_size) return if (cand_downscale) cand_size < best_size else cand_size > best_size;
        return self.scale == scale and best.scale != scale;
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
            const data = read(self.arena.child_allocator, path) orelse continue;
            defer self.arena.child_allocator.free(data);
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
        var best_dir: ?Directory = null;
        var distance: i64 = std.math.maxInt(i64);
        for ([_]bool{ true, false }) |exact| {
            for (theme.dirs.items) |dir| {
                if (dir.size <= 0 or !validRelative(dir.path)) continue;
                const d = dir.distance(size, scale);
                if (exact and (d != 0 or dir.scale != scale)) continue;
                if (!exact and !dir.betterThan(d, best_dir, distance, size, scale)) continue;
                for (self.roots) |root| {
                    if (try self.file(root, theme.name, dir.path, name)) |path| {
                        if (exact) return path;
                        best = path;
                        best_dir = dir;
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
fn read(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    return files.readFile(a, path, 1 << 20) catch null;
}

// The desktop shares icon lookup metadata for the lifetime of the UI.
const Cache = struct {
    allocator: std.mem.Allocator,
    resolver: ?Resolver = null,
    settings: ?*@import("desktop-gsettings.zig").Settings = null,
};
var cache: ?Cache = null;

pub fn init(allocator: std.mem.Allocator) void {
    std.debug.assert(cache == null);
    cache = .{ .allocator = allocator };
}

pub fn deinit() void {
    if (cache) |*value| {
        if (value.resolver) |*resolver| resolver.deinit();
        if (value.settings) |settings| settings.close();
    }
    cache = null;
}

fn themeChanged(_: ?*anyopaque, key: []const u8) void {
    if (!std.mem.eql(u8, key, "icon-theme")) return;
    if (cache) |*value| {
        if (value.resolver) |*resolver| resolver.deinit();
        value.resolver = null;
    }
}

fn makeResolver(a: std.mem.Allocator, settings: ?*@import("desktop-gsettings.zig").Settings) !Resolver {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    var roots: std.ArrayList([]const u8) = .empty;
    for ([_][:0]const u8{ "DESKTOP_PANEL_ICON_PATH", "DESKTOP_APPS_ICON_PATH" }) |name| if (c.__zig.getenv(name)) |path| try roots.append(alloc, std.mem.span(path));
    try roots.append(alloc, try std.fmt.allocPrint(alloc, "{s}/.icons", .{files.home()}));
    try roots.append(alloc, try std.fmt.allocPrint(alloc, "{s}/icons", .{files.dataHome()}));
    const dirs = if (c.__zig.getenv("XDG_DATA_DIRS")) |value| std.mem.span(value) else "/usr/local/share:/usr/share";
    var paths = std.mem.splitScalar(u8, dirs, ':');
    while (paths.next()) |path| if (std.fs.path.isAbsolute(path)) {
        try roots.append(alloc, try std.fmt.allocPrint(alloc, "{s}/icons", .{path}));
    };
    try roots.append(alloc, "/usr/share/pixmaps");
    var theme: []const u8 = "Adwaita";
    if (settings) |prefs| {
        const name = prefs.string(alloc, "icon-theme");
        if (validName(name)) theme = name;
    }
    return Resolver.init(a, roots.items, theme);
}

pub fn load(a: std.mem.Allocator, name: [:0]const u8, size: u32, scale: u32, tint: ?Color) ?Image {
    if (size == 0 or size > 4096 or scale == 0 or scale > 8) return null;
    if (std.fs.path.isAbsolute(name)) return loadPath(a, name, size * scale, tint);
    if (cache) |*value| {
        if (value.settings == null) if (c.__zig.settings(value.allocator, "org.gnome.desktop.interface", null)) |settings| {
            value.settings = settings;
            settings.watch(&themeChanged, null) catch {};
        };
        if (value.resolver == null) value.resolver = makeResolver(value.allocator, value.settings) catch return null;
        const path = (value.resolver.?.lookup(name, size, scale) catch return null) orelse return null;
        return loadPath(a, path, size * scale, tint);
    }
    var resolver = makeResolver(a, null) catch return null;
    defer resolver.deinit();
    const path = (resolver.lookup(name, size, scale) catch return null) orelse return null;
    return loadPath(a, path, size * scale, tint);
}

fn loadPath(a: std.mem.Allocator, path: [:0]const u8, physical: u32, tint: ?Color) ?Image {
    if (tint) |rgba| {
        if (std.mem.endsWith(u8, path, ".symbolic.png")) return symbolicPng(a, path, physical, rgba);
        for ([_][]const u8{ "-symbolic.svg", "-symbolic-ltr.svg", "-symbolic-rtl.svg" }) |suffix| {
            if (std.mem.endsWith(u8, path, suffix)) return symbolic(a, path, physical, rgba);
        }
    }
    return decode.file(a, path, physical);
}

/// Loads a GIcon, falling back to a copy of `fallback` or then a named icon.
pub fn loadThemed(a: std.mem.Allocator, icon: ?*c.GIcon, size: u32, fallback: ?Image, fallback_name: ?[:0]const u8) ?Image {
    if (size == 0) return null;
    if (icon) |value| {
        if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(value)), g_themed_icon_get_type()) != 0) {
            const names = g_themed_icon_get_names(value);
            var i: usize = 0;
            while (names[i]) |name| : (i += 1) if (load(a, std.mem.span(name), size, 1, foreground)) |image| return image;
        } else if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(value)), g_file_icon_get_type()) != 0) {
            if (g_file_get_path(g_file_icon_get_file(value))) |path| {
                defer c.g_free(path);
                if (load(a, std.mem.span(path), size, 1, foreground)) |image| return image;
            }
        }
        if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(value)), g_loadable_icon_get_type()) != 0) {
            if (g_loadable_icon_load(value, @intCast(size), null, null, null)) |stream| {
                defer c.g_object_unref(stream);
                if (decode.stream(a, stream, size)) |image| return image;
            }
        }
    }
    if (fallback) |image| return decode.clone(a, image);
    if (fallback_name) |name| return load(a, name, size, 1, null);
    return null;
}

fn symbolic(a: std.mem.Allocator, path: [:0]const u8, size: u32, tint: Color) ?Image {
    const data = decode.read(a, path) orelse return null;
    defer a.free(data);
    const channel = struct {
        fn f(value: f64) u32 {
            return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
        }
    }.f;
    const color: decode.Color = .{ .rgb = channel(tint.red) << 16 | channel(tint.green) << 8 | channel(tint.blue) };
    return decode.symbolic(a, data, size, .{ .foreground = color }, tint.alpha);
}

/// Recolors GTK's symbolic PNG palette: black takes the tint, while pure red,
/// green and blue select the success, warning and error colors.
fn symbolicPng(a: std.mem.Allocator, path: [:0]const u8, size: u32, tint: Color) ?Image {
    const image = decode.file(a, path, size) orelse return null;
    const colors = [_][3]u32{
        .{ @intFromFloat(std.math.clamp(tint.red, 0, 1) * 255), @intFromFloat(std.math.clamp(tint.green, 0, 1) * 255), @intFromFloat(std.math.clamp(tint.blue, 0, 1) * 255) },
        .{ 77, 153, 5 },
        .{ 244, 120, 61 },
        .{ 203, 0, 0 },
    };
    const opacity: u32 = @intFromFloat(std.math.clamp(tint.alpha, 0, 1) * 255);
    for (std.mem.bytesAsSlice(u32, image.pixels)) |*pixel| {
        const alpha = pixel.* >> 24;
        if (alpha == 0) {
            pixel.* = 0;
            continue;
        }
        var source: [3]u32 = undefined;
        for (&source, [_]u5{ 16, 8, 0 }) |*channel, shift| channel.* = @min(255, (((pixel.* >> shift) & 255) * 255 + alpha / 2) / alpha);
        const weights = [4]u32{ 255 -| (source[0] + source[1] + source[2]), source[0], source[1], source[2] };
        var rgb: [3]u32 = @splat(0);
        for (colors, weights) |color, weight| for (&rgb, color) |*out, channel| {
            out.* += channel * weight;
        };
        const result = alpha * opacity / 255;
        pixel.* = result << 24;
        for (rgb, [_]u5{ 16, 8, 0 }) |channel, shift| pixel.* |= ((@min(255, channel / 255) * result + 127) / 255) << shift;
    }
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

test "tied icon distance prefers downscaling larger icons over upscaling smaller ones" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const index =
        "[Icon Theme]\nName=hicolor\nDirectories=64x64/apps,128x128/apps\n" ++
        "[64x64/apps]\nSize=64\nType=Threshold\n" ++
        "[128x128/apps]\nSize=128\nType=Threshold\n";
    try fixture.put("hicolor/index.theme", index);
    try fixture.put("hicolor/64x64/apps/firefox.png", "");
    try fixture.put("hicolor/128x128/apps/firefox.png", "");
    var theme = try Resolver.init(std.testing.allocator, &.{fixture.root}, "hicolor");
    defer theme.deinit();
    try std.testing.expect(std.mem.endsWith(u8, (try theme.lookup("firefox", 96, 1)).?, "128x128/apps/firefox.png"));
}

fn pixelAt(image: Image, x: usize, y: usize) u32 {
    return std.mem.bytesAsSlice(u32, image.pixels)[y * image.stride / 4 + x];
}

fn premultiplied(rgb: u32, alpha: u32) u32 {
    var pixel = alpha << 24;
    for ([_]u5{ 16, 8, 0 }) |shift| pixel |= ((((rgb >> shift) & 255) * alpha + 127) / 255) << shift;
    return pixel;
}

test "symbolic SVG icons use the GTK palette, opacity and scale" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.put("Test/index.theme", "[Icon Theme]\nName=Test\nDirectories=scalable/status\n[scalable/status]\nSize=16\nType=Scalable\nMinSize=1\nMaxSize=64\n");
    try fixture.put("Test/scalable/status/probe-symbolic.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\"><path d=\"M0 0h4v16H0z\"/><path class=\"success\" d=\"M4 0h4v16H4z\"/><path class=\"warning\" d=\"M8 0h4v16H8z\"/><path class=\"error\" d=\"M12 0h4v16h-4z\"/></svg>");
    var lookup = try Resolver.init(std.testing.allocator, &.{fixture.root}, "Test");
    defer lookup.deinit();
    const tint: Color = .{ .red = 0.3, .green = 0.6, .blue = 0.9, .alpha = 0.7 };
    for ([_]u32{ 1, 2 }) |scale| {
        const image = symbolic(std.testing.allocator, (try lookup.lookup("probe-symbolic", 16, scale)).?, 16 * scale, tint) orelse return error.IconDecode;
        defer decode.free(std.testing.allocator, image);
        try std.testing.expectEqual(16 * scale, image.width);
        try std.testing.expectEqual(16 * scale, image.height);
        // Sample each stripe's center: the tint, then success, warning and error.
        for ([_]u32{ 0x4d99e6, 0x4e9a06, 0xf5793e, 0xcc0000 }, 0..) |rgb, stripe| {
            const pixel = pixelAt(image, (stripe * 4 + 2) * scale, 8 * scale);
            const expected = premultiplied(rgb, 179);
            for ([_]u5{ 24, 16, 8, 0 }) |shift| {
                const delta = @as(i32, @intCast((pixel >> shift) & 255)) - @as(i32, @intCast((expected >> shift) & 255));
                try std.testing.expect(@abs(delta) <= 1);
            }
        }
    }
}

test "symbolic PNG palettes and file GIcons decode to premultiplied images" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const palette = [_]u32{ 0xff000000, 0xffff0000, 0xff00ff00, 0x80000080 };
    const data = try @import("desktop-png.zig").encode(std.testing.allocator, .{ .pixels = std.mem.sliceAsBytes(&palette), .width = 4, .height = 1, .stride = 16, .alpha = true });
    defer std.testing.allocator.free(data);
    try fixture.put("palette-symbolic.symbolic.png", data);
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/palette-symbolic.symbolic.png", .{fixture.root}, 0);
    defer std.testing.allocator.free(path);
    const tinted = load(std.testing.allocator, path, 4, 1, .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.5 }) orelse return error.IconDecode;
    defer decode.free(std.testing.allocator, tinted);
    try std.testing.expectEqualSlices(u32, &.{ premultiplied(0xffffff, 127), premultiplied(0x4d9905, 127), premultiplied(0xf4783d, 127), premultiplied(0xcb0000, 63) }, std.mem.bytesAsSlice(u32, tinted.pixels));
    const icon = g_icon_new_for_string(path, null) orelse return error.InvalidIcon;
    defer c.g_object_unref(icon);
    const loaded = loadThemed(std.testing.allocator, icon, 8, null, null) orelse return error.IconDecode;
    defer decode.free(std.testing.allocator, loaded);
    try std.testing.expectEqual(@as(u32, 8), loaded.width);
    try std.testing.expectEqual(@as(u32, 2), loaded.height);
}

test "native icon lookup renders installed Adwaita symbols at both output scales" {
    try @import("desktop-runtime.zig").setup(std.testing.allocator);
    init(std.testing.allocator);
    defer @import("desktop-gsettings.zig").deinit();
    defer deinit();
    for ([_][:0]const u8{ "view-app-grid-symbolic", "view-refresh-symbolic", "audio-volume-high-symbolic", "battery-level-50-symbolic", "dark-mode-symbolic" }) |name| {
        for ([_]u32{ 1, 2 }) |scale| {
            const image = load(std.testing.allocator, name, 16, scale, white) orelse return error.InstalledIconMissing;
            defer decode.free(std.testing.allocator, image);
            try std.testing.expectEqual(16 * scale, image.width);
            var visible = false;
            for (std.mem.bytesAsSlice(u32, image.pixels)) |pixel| visible = visible or pixel >> 24 != 0;
            try std.testing.expect(visible);
        }
    }
}
