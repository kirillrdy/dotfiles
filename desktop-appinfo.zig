//! Installed applications from XDG desktop entries, in Zig, with the semantics
//! the desktop previously took from GIO's GDesktopAppInfo: the application
//! directories and desktop file IDs, GKeyFile parsing with localized keys,
//! visibility rules, Exec field codes and command-line parsing, and launching
//! either by executing the command or by D-Bus activation.
//!
//! Applications are reference counted and owned by their callers. The catalog
//! of installed applications is cached for the main thread and rescanned when
//! an application directory changes.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const linux = std.os.linux;
const paths = @import("desktop-paths.zig");
const util = @import("desktop-util.zig");
const process = @import("desktop-process.zig");

pub const App = struct {
    refs: u32 = 1,
    arena: std.heap.ArenaAllocator,
    /// The desktop file ID, such as "org.gnome.Nautilus.desktop"; empty for commands.
    id: [:0]const u8 = "",
    filename: ?[:0]const u8 = null,
    name: [:0]const u8 = "Unnamed",
    /// X-GNOME-FullName when present, otherwise the name.
    display_name: [:0]const u8 = "Unnamed",
    /// The raw Icon value.
    icon_value: ?[:0]const u8 = null,
    /// The icon to load: an absolute path, or a theme name without an image suffix.
    icon: ?[:0]const u8 = null,
    exec: ?[:0]const u8 = null,
    path: ?[:0]const u8 = null,
    terminal: bool = false,
    no_display: bool = false,
    hidden: bool = false,
    dbus_activatable: bool = false,
    only_show_in: ?[]const []const u8 = null,
    not_show_in: ?[]const []const u8 = null,
    startup_wm_class: ?[:0]const u8 = null,
    /// The MimeType list, as written.
    mime_types: []const []const u8 = &.{},

    pub fn ref(self: *App) *App {
        self.refs += 1;
        return self;
    }

    pub fn unref(self: *App) void {
        self.refs -= 1;
        if (self.refs == 0) {
            var arena = self.arena;
            arena.deinit();
        }
    }

    /// Parses a desktop entry; null when GIO would not consider it an application.
    pub fn parse(gpa: std.mem.Allocator, data: []const u8, id: []const u8, filename: ?[]const u8) !?*App {
        var arena = std.heap.ArenaAllocator.init(gpa);
        const self = build(&arena, data, id, filename) catch |err| {
            arena.deinit();
            return if (err == error.NotApplication) null else err;
        };
        self.arena = arena;
        return self;
    }

    fn build(arena: *std.heap.ArenaAllocator, data: []const u8, id: []const u8, filename: ?[]const u8) !*App {
        const a = arena.allocator();
        const file = KeyFile.parse(a, data) catch return error.NotApplication;
        if (file.first_group == null or !std.mem.eql(u8, file.first_group.?, "Desktop Entry")) return error.NotApplication;
        const group = "Desktop Entry";
        const kind = file.string(group, "Type") orelse return error.NotApplication;
        if (!std.mem.eql(u8, kind, "Application")) return error.NotApplication;
        if (file.string(group, "TryExec")) |try_exec| if (try_exec.len > 0) {
            if (paths.findProgram(a, try_exec) == null) return error.NotApplication;
        };
        const exec = file.string(group, "Exec");
        if (exec) |command| if (command.len > 0) {
            const words = shellParse(a, command) catch return error.NotApplication;
            if (paths.findProgram(a, words[0]) == null) return error.NotApplication;
        };
        const languages = languageNames(a) catch &.{};
        const self = try a.create(App);
        self.* = .{ .arena = undefined };
        self.id = try a.dupeSentinel(u8, id, 0);
        self.filename = if (filename) |value| try a.dupeSentinel(u8, value, 0) else null;
        if (file.localeString(group, "Name", languages)) |value| self.name = value;
        self.display_name = file.localeString(group, "X-GNOME-FullName", languages) orelse self.name;
        self.icon_value = file.string(group, "Icon");
        if (file.localeString(group, "Icon", languages)) |value| self.icon = iconName(value);
        self.exec = exec;
        self.path = file.string(group, "Path");
        self.terminal = file.boolean(group, "Terminal");
        self.no_display = file.boolean(group, "NoDisplay");
        self.hidden = file.boolean(group, "Hidden");
        self.dbus_activatable = file.boolean(group, "DBusActivatable");
        self.only_show_in = file.list(group, "OnlyShowIn");
        self.not_show_in = file.list(group, "NotShowIn");
        self.startup_wm_class = file.string(group, "StartupWMClass");
        self.mime_types = file.list(group, "MimeType") orelse &.{};
        return self;
    }

    /// An application that runs `command`, like g_app_info_create_from_commandline.
    pub fn fromCommandLine(gpa: std.mem.Allocator, command: []const u8, name: []const u8) !*App {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const self = try a.create(App);
        self.* = .{ .arena = undefined, .exec = try a.dupeSentinel(u8, command, 0), .name = try a.dupeSentinel(u8, name, 0) };
        self.display_name = self.name;
        self.arena = arena;
        return self;
    }

    /// Whether menus list the application, honouring XDG_CURRENT_DESKTOP.
    pub fn shouldShow(self: *const App) bool {
        if (self.no_display) return false;
        var desktops = std.mem.splitScalar(u8, util.env("XDG_CURRENT_DESKTOP") orelse "", ':');
        while (desktops.next()) |desktop| {
            if (desktop.len == 0) continue;
            if (self.only_show_in) |names| for (names) |value| if (std.mem.eql(u8, value, desktop)) return true;
            if (self.not_show_in) |names| for (names) |value| if (std.mem.eql(u8, value, desktop)) return false;
        }
        return self.only_show_in == null;
    }

    /// Whether the command accepts URIs (%u or %U) rather than only local files.
    pub fn supportsUris(self: *const App) bool {
        const command = self.exec orelse return false;
        return std.mem.indexOf(u8, command, "%u") != null or std.mem.indexOf(u8, command, "%U") != null;
    }

    /// The command with field codes expanded and no files, split into arguments.
    pub fn argv(self: *const App, a: std.mem.Allocator) ![][:0]u8 {
        var none: []const []const u8 = &.{};
        return self.argvFor(a, &none);
    }

    /// The command for the next of `uris`, consuming those it uses, as GIO's
    /// expand_application_parameters: %u and %f take one, %U and %F take all,
    /// and a command without them gets one file appended. %f gives local paths
    /// and skips URIs without one.
    pub fn argvFor(self: *const App, a: std.mem.Allocator, uris: *[]const []const u8) ![][:0]u8 {
        const command = self.exec orelse return error.MissingCommand;
        var expanded: std.ArrayList(u8) = .empty;
        defer expanded.deinit(a);
        const offered = uris.len;
        var i: usize = 0;
        while (i < command.len) : (i += 1) {
            if (command[i] != '%' or i + 1 == command.len) {
                try expanded.append(a, command[i]);
                continue;
            }
            i += 1;
            try self.expandCode(a, &expanded, command[i], uris);
        }
        // GIO appends a file argument when no field code took one.
        if (offered > 0 and uris.len == offered) {
            try expanded.append(a, ' ');
            try self.expandCode(a, &expanded, 'f', uris);
        }
        return shellParse(a, expanded.items);
    }

    fn expandCode(self: *const App, a: std.mem.Allocator, out: *std.ArrayList(u8), code: u8, uris: *[]const []const u8) !void {
        switch (code) {
            '%' => try out.append(a, '%'),
            'i' => if (self.icon) |icon| {
                try out.appendSlice(a, "--icon ");
                try shellQuote(a, out, icon);
            },
            'c' => try shellQuote(a, out, self.name),
            'k' => if (self.filename) |filename| try shellQuote(a, out, filename),
            'u', 'f' => if (uris.len > 0) {
                try expandUri(a, out, code, uris.*[0]);
                uris.* = uris.*[1..];
            },
            'U', 'F' => {
                for (uris.*, 0..) |uri, n| {
                    if (n > 0) try out.append(a, ' ');
                    try expandUri(a, out, code, uri);
                }
                uris.* = uris.*[uris.len..];
            },
            // Deprecated and unknown codes expand to nothing.
            else => {},
        }
    }

    fn expandUri(a: std.mem.Allocator, out: *std.ArrayList(u8), code: u8, uri: []const u8) !void {
        if (code == 'u' or code == 'U') return shellQuote(a, out, uri);
        // %f and %F want paths; a plain path is already one.
        if (std.fs.path.isAbsolute(uri)) return shellQuote(a, out, uri);
        const path = paths.pathFromUri(a, uri) orelse return;
        try shellQuote(a, out, path);
    }

    /// Starts the application with `options`: D-Bus activation or Open when the
    /// entry asks for it, otherwise its command once per URI group, in a
    /// terminal when Terminal is set. Errors that are known at once are
    /// returned; otherwise `done`, when given, later receives the outcome on
    /// the main loop.
    pub fn launch(self: *const App, gpa: std.mem.Allocator, options: LaunchOptions, done: ?Done, context: ?*anyopaque) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (self.dbus_activatable) if (busName(self.id)) |name| return activate(gpa, name, options, done, context);
        const directory = if (self.path) |value| (if (value.len > 0) value else null) else null;
        var environment: std.ArrayList([:0]const u8) = .empty;
        if (options.activation_token) |token| {
            try environment.append(a, try std.fmt.allocPrintSentinel(a, "XDG_ACTIVATION_TOKEN={s}", .{token}, 0));
            try environment.append(a, try std.fmt.allocPrintSentinel(a, "DESKTOP_STARTUP_ID={s}", .{token}, 0));
        }
        if (self.filename) |filename| try environment.append(a, try std.fmt.allocPrintSentinel(a, "GIO_LAUNCHED_DESKTOP_FILE={s}", .{filename}, 0));
        var remaining = options.uris;
        while (true) {
            try process.spawnDetached(a, try self.launchArgsFor(a, &remaining), .{
                .directory = directory,
                .environment = environment.items,
                .pid_variable = if (self.filename != null) "GIO_LAUNCHED_DESKTOP_FILE_PID" else null,
            });
            if (remaining.len == 0) break;
        }
        if (done) |callback| Completion.later(gpa, callback, context, true);
    }

    /// The arguments `launch` executes without URIs.
    pub fn launchArgs(self: *const App, a: std.mem.Allocator) ![][:0]u8 {
        var none: []const []const u8 = &.{};
        return self.launchArgsFor(a, &none);
    }

    fn launchArgsFor(self: *const App, a: std.mem.Allocator, uris: *[]const []const u8) ![][:0]u8 {
        const args = try self.argvFor(a, uris);
        if (!self.terminal) return args;
        // GIO's terminal list does not consistently include Ghostty.
        const wrapped = try a.alloc([:0]u8, args.len + 2);
        wrapped[0] = try a.dupeSentinel(u8, "ghostty", 0);
        wrapped[1] = try a.dupeSentinel(u8, "-e", 0);
        @memcpy(wrapped[2..], args);
        return wrapped;
    }
};

pub const LaunchOptions = struct {
    uris: []const []const u8 = &.{},
    /// An xdg-activation token for the started application.
    activation_token: ?[]const u8 = null,
    /// Cancels a pending D-Bus activation, which then completes with failure.
    cancellable: ?*mainloop.Cancellable = null,
};

pub const Done = *const fn (?*anyopaque, bool) void;

/// Delivers a launch outcome on the main loop.
const Completion = struct {
    allocator: std.mem.Allocator,
    done: Done,
    context: ?*anyopaque,
    ok: bool,

    fn later(gpa: std.mem.Allocator, done: Done, context: ?*anyopaque, ok: bool) void {
        const self = gpa.create(Completion) catch return done(context, ok);
        self.* = .{ .allocator = gpa, .done = done, .context = context, .ok = ok };
        _ = mainloop.idle(self, deliver);
    }

    fn deliver(self: *Completion) bool {
        const done = self.done;
        const context = self.context;
        const ok = self.ok;
        self.allocator.destroy(self);
        done(context, ok);
        return false;
    }

    fn replied(data: ?*anyopaque, reply: @import("dbus").Reply) void {
        const self: *Completion = @ptrCast(@alignCast(data));
        const done = self.done;
        const context = self.context;
        self.allocator.destroy(self);
        done(context, reply == .ok);
    }

    fn ignored(_: ?*anyopaque, reply: @import("dbus").Reply) void {
        if (reply != .ok) std.log.warn("D-Bus activation failed: {s}", .{reply.failed.text});
    }
};


/// A desktop file ID without ".desktop", when it is a valid D-Bus name.
fn busName(id: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, id, ".desktop")) return null;
    const name = id[0 .. id.len - ".desktop".len];
    if (name.len == 0 or name.len > 255 or std.mem.indexOfScalar(u8, name, '.') == null) return null;
    var elements = std.mem.splitScalar(u8, name, '.');
    while (elements.next()) |element| {
        if (element.len == 0 or std.ascii.isDigit(element[0])) return null;
        for (element) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return null;
    }
    return name;
}

/// org.freedesktop.Application Activate, or Open with URIs, on the
/// application's well-known name, without waiting for the reply.
fn activate(gpa: std.mem.Allocator, name: []const u8, options: LaunchOptions, done: ?Done, context: ?*anyopaque) !void {
    const dbus = @import("dbus");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const object = try a.alloc(u8, name.len + 1);
    object[0] = '/';
    for (name, object[1..]) |byte, *out| out.* = switch (byte) {
        '.' => '/',
        '-' => '_',
        else => byte,
    };
    var entries: std.ArrayList(dbus.Dict([]const u8, dbus.Value).Entry) = .empty;
    if (options.activation_token) |token| {
        try entries.append(a, .{ .key = "activation-token", .value = .{ .string = token } });
        try entries.append(a, .{ .key = "desktop-startup-id", .value = .{ .string = token } });
    }
    const platform_data: dbus.Dict([]const u8, dbus.Value) = .{ .entries = entries.items };
    const target: dbus.Connection.Call = .{ .destination = name, .path = object, .interface = "org.freedesktop.Application", .member = if (options.uris.len > 0) "Open" else "Activate" };
    var handler: dbus.ReplyHandler = &Completion.ignored;
    var state: ?*anyopaque = null;
    if (done) |callback| {
        const completion = try gpa.create(Completion);
        completion.* = .{ .allocator = gpa, .done = callback, .context = context, .ok = false };
        handler = &Completion.replied;
        state = completion;
    }
    const loop = @import("desktop-dbus-loop.zig");
    if (options.uris.len > 0)
        loop.request(gpa, .session, target, .{ options.uris, platform_data }, 25000, options.cancellable, handler, state)
    else
        loop.request(gpa, .session, target, .{platform_data}, 25000, options.cancellable, handler, state);
}

/// GThemedIcon names drop image suffixes; absolute paths are files.
fn iconName(value: [:0]const u8) [:0]const u8 {
    if (std.fs.path.isAbsolute(value)) return value;
    for ([_][]const u8{ ".png", ".xpm", ".svg", ".svgz" }) |suffix| if (std.mem.endsWith(u8, value, suffix)) {
        // The arena owns the value, so it can be shortened in place.
        const shortened: [*:0]u8 = @constCast(value.ptr);
        shortened[value.len - suffix.len] = 0;
        return shortened[0 .. value.len - suffix.len :0];
    };
    return value;
}

/// The languages to try for localized keys, as g_get_language_names: each
/// locale from $LANGUAGE, $LC_ALL, $LC_MESSAGES or $LANG with its variants
/// from most to least specific, then "C".
pub fn languageNames(a: std.mem.Allocator) ![]const []const u8 {
    var value: []const u8 = "C";
    for ([_][:0]const u8{ "LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG" }) |name| if (util.env(name)) |found| if (found.len > 0) {
        value = found;
        break;
    };
    var names: std.ArrayList([]const u8) = .empty;
    var locales = std.mem.splitScalar(u8, value, ':');
    while (locales.next()) |locale| if (locale.len > 0) try appendVariants(a, &names, locale);
    try names.append(a, "C");
    return names.toOwnedSlice(a);
}

/// language[_territory][.codeset][@modifier], most specific first.
fn appendVariants(a: std.mem.Allocator, names: *std.ArrayList([]const u8), locale: []const u8) !void {
    const at = std.mem.indexOfScalar(u8, locale, '@');
    const modifier = if (at) |index| locale[index..] else "";
    const base = locale[0 .. at orelse locale.len];
    const dot = std.mem.indexOfScalar(u8, base, '.');
    const codeset = if (dot) |index| base[index..] else "";
    const before_codeset = base[0 .. dot orelse base.len];
    const underscore = std.mem.indexOfScalar(u8, before_codeset, '_');
    const territory = if (underscore) |index| before_codeset[index..] else "";
    const language = before_codeset[0 .. underscore orelse before_codeset.len];
    const present: u3 = @as(u3, @intFromBool(codeset.len > 0)) | @as(u3, @intFromBool(territory.len > 0)) << 1 | @as(u3, @intFromBool(modifier.len > 0)) << 2;
    var mask: u4 = 8;
    while (mask > 0) {
        mask -= 1;
        const parts: u3 = @intCast(mask);
        if (parts & ~present != 0) continue;
        try names.append(a, try std.mem.concat(a, u8, &.{
            language,
            if (parts & 2 != 0) territory else "",
            if (parts & 1 != 0) codeset else "",
            if (parts & 4 != 0) modifier else "",
        }));
    }
}

/// The parts of GKeyFile the desktop entry specification needs. Values are
/// decoded into the allocator given to `parse`, normally an arena.
pub const KeyFile = struct {
    allocator: std.mem.Allocator,
    first_group: ?[]const u8 = null,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { group: []const u8, key: []const u8, value: []const u8 };

    pub fn parse(a: std.mem.Allocator, data: []const u8) !KeyFile {
        if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidKeyFile;
        var self: KeyFile = .{ .allocator = a };
        var group: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimStart(u8, std.mem.trimEnd(u8, raw_line, "\r"), " \t");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                const close = std.mem.indexOfScalar(u8, line, ']') orelse return error.InvalidKeyFile;
                if (std.mem.trimEnd(u8, line[close + 1 ..], " \t").len != 0) return error.InvalidKeyFile;
                group = line[1..close];
                if (self.first_group == null) self.first_group = group;
                continue;
            }
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidKeyFile;
            const current = group orelse return error.InvalidKeyFile;
            const key = std.mem.trimEnd(u8, line[0..equals], " \t");
            if (key.len == 0) return error.InvalidKeyFile;
            const value = std.mem.trimStart(u8, line[equals + 1 ..], " \t");
            // A later duplicate replaces the earlier value.
            for (self.entries.items) |*entry| {
                if (std.mem.eql(u8, entry.group, current) and std.mem.eql(u8, entry.key, key)) {
                    entry.value = value;
                    break;
                }
            } else try self.entries.append(a, .{ .group = current, .key = key, .value = value });
        }
        return self;
    }

    fn raw(self: *const KeyFile, group: []const u8, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.group, group) and std.mem.eql(u8, entry.key, key)) return entry.value;
        return null;
    }

    pub fn string(self: *const KeyFile, group: []const u8, key: []const u8) ?[:0]const u8 {
        return self.unescape(self.raw(group, key) orelse return null) catch null;
    }

    /// The value for the first matching language, as g_key_file_get_locale_string.
    pub fn localeString(self: *const KeyFile, group: []const u8, key: []const u8, languages: []const []const u8) ?[:0]const u8 {
        var name: [256]u8 = undefined;
        for (languages) |language| {
            const localized = std.fmt.bufPrint(&name, "{s}[{s}]", .{ key, language }) catch continue;
            if (self.string(group, localized)) |value| return value;
        }
        return self.string(group, key);
    }

    pub fn boolean(self: *const KeyFile, group: []const u8, key: []const u8) bool {
        const value = std.mem.trimEnd(u8, self.raw(group, key) orelse return false, " \t");
        return std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    }

    /// A semicolon-separated list; an escaped "\;" stays in its element.
    pub fn list(self: *const KeyFile, group: []const u8, key: []const u8) ?[]const []const u8 {
        const value = self.raw(group, key) orelse return null;
        var items: std.ArrayList([]const u8) = .empty;
        var start: usize = 0;
        var i: usize = 0;
        while (i < value.len) : (i += 1) {
            if (value[i] == '\\' and i + 1 < value.len) {
                i += 1;
                continue;
            }
            if (value[i] != ';') continue;
            items.append(self.allocator, self.unescape(value[start..i]) catch return null) catch return null;
            start = i + 1;
        }
        if (start < value.len) items.append(self.allocator, self.unescape(value[start..]) catch return null) catch return null;
        return items.toOwnedSlice(self.allocator) catch null;
    }

    /// GKeyFile escapes: \s \n \t \r \\ and, inside lists, \;.
    fn unescape(self: *const KeyFile, value: []const u8) ![:0]const u8 {
        var out = try self.allocator.allocSentinel(u8, value.len, 0);
        var len: usize = 0;
        var i: usize = 0;
        while (i < value.len) : (i += 1) {
            var byte = value[i];
            if (byte == '\\' and i + 1 < value.len) {
                i += 1;
                byte = switch (value[i]) {
                    's' => ' ',
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    ';' => ';',
                    else => return error.InvalidEscape,
                };
            }
            out[len] = byte;
            len += 1;
        }
        out[len] = 0;
        return out[0..len :0];
    }
};

pub const shellParse = process.shellParse;
pub const shellQuote = process.shellQuote;

/// The directories searched for desktop files, highest priority first.
fn applicationDirectories(a: std.mem.Allocator) ![]const []const u8 {
    var directories: std.ArrayList([]const u8) = .empty;
    try directories.append(a, try std.fmt.allocPrint(a, "{s}/applications", .{paths.dataHome()}));
    const system = util.env("XDG_DATA_DIRS") orelse "";
    var dirs = std.mem.splitScalar(u8, if (system.len > 0) system else "/usr/local/share/:/usr/share/", ':');
    while (dirs.next()) |dir| if (dir.len > 0) {
        try directories.append(a, try std.fmt.allocPrint(a, "{s}/applications", .{std.mem.trimEnd(u8, dir, "/")}));
    };
    // Nixpkgs patches GIO to also search the Nix profiles, after the XDG directories.
    try directories.append(a, "/nix/var/nix/profiles/system/sw/share/applications");
    const state = util.env("XDG_STATE_HOME") orelse "";
    if (state.len > 0)
        try directories.append(a, try std.fmt.allocPrint(a, "{s}/nix/profiles/profile/share/applications", .{state}))
    else
        try directories.append(a, try std.fmt.allocPrint(a, "{s}/.local/state/nix/profiles/profile/share/applications", .{paths.home()}));
    try directories.append(a, try std.fmt.allocPrint(a, "/nix/var/nix/profiles/per-user/{s}/profile/share/applications", .{paths.userName()}));
    try directories.append(a, try std.fmt.allocPrint(a, "/etc/profiles/per-user/{s}/share/applications", .{paths.userName()}));
    return directories.toOwnedSlice(a);
}

/// Every application, each ID once from the highest-priority directory; a
/// Hidden entry hides that ID entirely. The caller unrefs each application.
pub fn all(gpa: std.mem.Allocator) ![]*App {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var apps: std.ArrayList(*App) = .empty;
    errdefer {
        for (apps.items) |app| app.unref();
        apps.deinit(gpa);
    }
    for (try applicationDirectories(a)) |directory| try collect(gpa, a, directory, "", &seen, &apps);
    return apps.toOwnedSlice(gpa);
}

fn collect(gpa: std.mem.Allocator, a: std.mem.Allocator, directory: []const u8, prefix: []const u8, seen: *std.StringHashMapUnmanaged(void), apps: *std.ArrayList(*App)) !void {
    const entries = paths.list(a, directory) catch return;
    for (entries) |entry| {
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ directory, entry.name });
        const kind = if (entry.resolved) entry.kind else paths.kind(full);
        if (kind == .directory) {
            try collect(gpa, a, full, try std.fmt.allocPrint(a, "{s}{s}-", .{ prefix, entry.name }), seen, apps);
            continue;
        }
        if (kind != .file or !std.mem.endsWith(u8, entry.name, ".desktop")) continue;
        const id = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, entry.name });
        if (seen.contains(id)) continue;
        try seen.put(a, id, {});
        const data = paths.readFile(a, full, 1 << 20) catch continue;
        const app = try App.parse(gpa, data, id, full) orelse continue;
        if (app.hidden) {
            app.unref();
            continue;
        }
        apps.append(gpa, app) catch |err| {
            app.unref();
            return err;
        };
    }
}

/// The application with a desktop file ID such as "org.gnome.Nautilus.desktop".
pub fn lookup(gpa: std.mem.Allocator, id: []const u8) ?*App {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (!std.mem.endsWith(u8, id, ".desktop") or std.mem.indexOfScalar(u8, id, '/') != null) return null;
    const directories = applicationDirectories(a) catch return null;
    for (directories) |directory| {
        // "a-b-c.desktop" may be a-b-c.desktop, a/b-c.desktop, a-b/c.desktop or a/b/c.desktop.
        const dashes = std.mem.count(u8, id, "-");
        if (dashes > 12) continue;
        var choice: u32 = 0;
        while (choice < @as(u32, 1) << @intCast(dashes)) : (choice += 1) {
            const relative = a.dupe(u8, id) catch return null;
            var bit: u5 = 0;
            for (relative) |*byte| if (byte.* == '-') {
                if (choice & (@as(u32, 1) << bit) != 0) byte.* = '/';
                bit += 1;
            };
            const full = std.fmt.allocPrint(a, "{s}/{s}", .{ directory, relative }) catch return null;
            if (paths.kind(full) != .file) continue;
            const data = paths.readFile(a, full, 1 << 20) catch continue;
            const app = (App.parse(gpa, data, id, full) catch return null) orelse return null;
            if (app.hidden) {
                app.unref();
                return null;
            }
            return app;
        }
    }
    return null;
}

/// A directory GIO consults for associations: its mimeapps.list files and,
/// for application directories, the mimeinfo.cache update-desktop-database
/// writes there.
const AssociationDir = struct {
    lists: []const KeyFile,
    applications: ?[]const u8,
    cache: ?KeyFile = null,
};

/// Configuration directories, then application directories, highest priority
/// first; each reads the lists for the current desktops, then mimeapps.list.
fn associationDirs(a: std.mem.Allocator) ![]const AssociationDir {
    var desktops: std.ArrayList([]const u8) = .empty;
    var current = std.mem.splitScalar(u8, util.env("XDG_CURRENT_DESKTOP") orelse "", ':');
    while (current.next()) |desktop| if (desktop.len > 0) try desktops.append(a, try std.ascii.allocLowerString(a, desktop));
    var bases: std.ArrayList(struct { path: []const u8, applications: bool }) = .empty;
    try bases.append(a, .{ .path = paths.configHome(), .applications = false });
    const config = util.env("XDG_CONFIG_DIRS") orelse "";
    var config_dirs = std.mem.splitScalar(u8, if (config.len > 0) config else "/etc/xdg", ':');
    while (config_dirs.next()) |dir| if (dir.len > 0) try bases.append(a, .{ .path = std.mem.trimEnd(u8, dir, "/"), .applications = false });
    for (try applicationDirectories(a)) |dir| try bases.append(a, .{ .path = dir, .applications = true });
    var result: std.ArrayList(AssociationDir) = .empty;
    for (bases.items) |base| {
        var lists: std.ArrayList(KeyFile) = .empty;
        for (desktops.items) |desktop| if (readKeyFile(a, try std.fmt.allocPrint(a, "{s}/{s}-mimeapps.list", .{ base.path, desktop }))) |file| try lists.append(a, file);
        if (readKeyFile(a, try std.fmt.allocPrint(a, "{s}/mimeapps.list", .{base.path}))) |file| try lists.append(a, file);
        try result.append(a, .{
            .lists = lists.items,
            .applications = if (base.applications) base.path else null,
            .cache = if (base.applications) readKeyFile(a, try std.fmt.allocPrint(a, "{s}/mimeinfo.cache", .{base.path})) else null,
        });
    }
    return result.toOwnedSlice(a);
}

fn readKeyFile(a: std.mem.Allocator, path: []const u8) ?KeyFile {
    const data = paths.readFile(a, path, 4 << 20) catch return null;
    return KeyFile.parse(a, data) catch null;
}

/// The IDs a group gives for `mime`, with keys unaliased as GIO does.
fn associated(file: *const KeyFile, group: []const u8, mime: []const u8, db: ?*const @import("desktop-mime.zig").Database) []const []const u8 {
    for (file.entries.items) |entry| {
        if (!std.mem.eql(u8, entry.group, group)) continue;
        const key = if (db) |value| value.unalias(entry.key) else entry.key;
        if (std.mem.eql(u8, key, mime)) return file.list(group, entry.key) orelse &.{};
    }
    return &.{};
}

fn contains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}

/// Whether an application directory before `dir` provides `id`, hiding it here.
fn masked(dirs: []const AssociationDir, dir: usize, apps: []const *App, id: []const u8) bool {
    const app = for (apps) |candidate| {
        if (std.mem.eql(u8, candidate.id, id)) break candidate;
    } else return false;
    const filename = app.filename orelse return false;
    for (dirs[0..dir]) |earlier| {
        const directory = earlier.applications orelse continue;
        if (std.mem.startsWith(u8, filename, directory) and filename.len > directory.len and filename[directory.len] == '/') return true;
    }
    return false;
}

/// The application GIO's g_app_info_get_default_for_type picks: for the type
/// and then each ancestor, the defaults from every mimeapps.list, then added
/// associations and each directory's mimeinfo.cache, skipping removed ones.
pub fn defaultFor(gpa: std.mem.Allocator, content_type: []const u8, must_support_uris: bool) ?*App {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const db = @import("desktop-mime.zig").shared();
    const types: []const []const u8 = if (db) |value| value.ancestry(a, content_type) catch return null else &.{content_type};
    const dirs = associationDirs(a) catch return null;
    const apps = all(gpa) catch return null;
    defer {
        for (apps) |app| app.unref();
        gpa.free(apps);
    }
    var blocklist: std.ArrayList([]const u8) = .empty;
    for (types) |mime| {
        var results: std.ArrayList([]const u8) = .empty;
        for (dirs) |dir| for (dir.lists) |*file| {
            for (associated(file, "Default Applications", mime, db)) |id| if (!contains(results.items, id)) results.append(a, id) catch return null;
        };
        for (dirs, 0..) |dir, index| {
            for (dir.lists) |*file| {
                for (associated(file, "Added Associations", mime, db)) |id| {
                    if (!masked(dirs, index, apps, id) and !contains(blocklist.items, id) and !contains(results.items, id)) results.append(a, id) catch return null;
                }
                for (associated(file, "Removed Associations", mime, db)) |id| {
                    if (!masked(dirs, index, apps, id) and !contains(blocklist.items, id) and !contains(results.items, id)) blocklist.append(a, id) catch return null;
                }
            }
            if (dir.cache) |*cache| for (associated(cache, "MIME Cache", mime, db)) |id| {
                if (!masked(dirs, index, apps, id) and !contains(blocklist.items, id) and !contains(results.items, id)) results.append(a, id) catch return null;
            };
        }
        for (results.items) |id| {
            const app = for (apps) |candidate| {
                if (std.mem.eql(u8, candidate.id, id)) break candidate;
            } else continue;
            if (must_support_uris and !app.supportsUris()) continue;
            return app.ref();
        }
    }
    return null;
}

/// The handler for "x-scheme-handler/<scheme>".
pub fn defaultForScheme(gpa: std.mem.Allocator, scheme: []const u8) ?*App {
    const prefix = "x-scheme-handler/";
    const mime = std.fmt.allocPrint(gpa, prefix ++ "{s}", .{scheme}) catch return null;
    defer gpa.free(mime);
    for (mime[prefix.len..]) |*byte| byte.* = std.ascii.toLower(byte.*);
    return defaultFor(gpa, mime, false);
}

/// A URI's scheme as RFC 3986 defines it, or null.
pub fn uriScheme(uri: []const u8) ?[]const u8 {
    if (uri.len == 0 or !std.ascii.isAlphabetic(uri[0])) return null;
    for (uri, 0..) |byte, i| {
        if (byte == ':') return if (i > 0) uri[0..i] else null;
        if (!(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '-' or byte == '.')) return null;
    }
    return null;
}

/// Opens a URI with its default handler, as g_app_info_launch_default_for_uri:
/// the scheme's handler, or for a local file the handler of its content type.
pub fn launchDefaultForUri(gpa: std.mem.Allocator, uri: []const u8, options: LaunchOptions, done: ?Done, context: ?*anyopaque) !void {
    const scheme = uriScheme(uri) orelse return error.InvalidUri;
    const app = defaultForScheme(gpa, scheme) orelse blk: {
        if (!std.ascii.eqlIgnoreCase(scheme, "file")) return error.NoHandler;
        const path = paths.pathFromUri(gpa, uri) orelse return error.InvalidUri;
        defer gpa.free(path);
        const db = @import("desktop-mime.zig").shared() orelse return error.NoHandler;
        break :blk defaultFor(gpa, db.forFile(path), false) orelse return error.NoHandler;
    };
    defer app.unref();
    var launch_options = options;
    const list = [_][]const u8{uri};
    launch_options.uris = &list;
    try app.launch(gpa, launch_options, done, context);
}

test "key files and locales" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file = try KeyFile.parse(a,
        \\# comment
        \\[Desktop Entry]
        \\Name = Files
        \\Name[de]=Dateien
        \\Name[de_DE@euro]=Dateien (Euro)
        \\Comment=a\sb\\c\nd
        \\OnlyShowIn=GNOME;KDE\;x;
        \\Terminal=true
        \\Name=Files Again
        \\[Other]
        \\Name=Ignored
    );
    try std.testing.expectEqualStrings("Files Again", file.string("Desktop Entry", "Name").?);
    try std.testing.expectEqualStrings("a b\\c\nd", file.string("Desktop Entry", "Comment").?);
    try std.testing.expect(file.boolean("Desktop Entry", "Terminal"));
    const show = file.list("Desktop Entry", "OnlyShowIn").?;
    try std.testing.expectEqual(@as(usize, 2), show.len);
    try std.testing.expectEqualStrings("KDE;x", show[1]);
    var languages: std.ArrayList([]const u8) = .empty;
    try appendVariants(a, &languages, "de_DE.UTF-8@euro");
    try std.testing.expectEqualStrings("de_DE.UTF-8@euro", languages.items[0]);
    try std.testing.expectEqualStrings("de_DE@euro", languages.items[1]);
    try std.testing.expectEqualStrings("de", languages.items[languages.items.len - 1]);
    try std.testing.expectEqualStrings("Dateien (Euro)", file.localeString("Desktop Entry", "Name", languages.items).?);
    try std.testing.expectError(error.InvalidKeyFile, KeyFile.parse(a, "[Desktop Entry]\nno equals\n"));
}

test "Exec field codes expand like GIO" {
    const app = (try App.parse(std.testing.allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=It's Mine
        \\Icon=mine.png
        \\Exec=sh -c "echo %%" %F %u %i %c %k --flag=%d
    , "mine.desktop", "/tmp/mine dir/mine.desktop")).?;
    defer app.unref();
    try std.testing.expectEqualStrings("mine", app.icon.?);
    try std.testing.expectEqualStrings("mine.png", app.icon_value.?);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try app.argv(arena.allocator());
    const expected = [_][]const u8{ "sh", "-c", "echo %", "--icon", "mine", "It's Mine", "/tmp/mine dir/mine.desktop", "--flag=" };
    try std.testing.expectEqual(expected.len, args.len);
    for (expected, args) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "missing application lookup returns null" {
    try std.testing.expect(lookup(std.testing.allocator, "desktop-appinfo-test-missing.desktop") == null);
}

test "URIs expand into field codes like GIO" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { exec: []const u8, uris: []const []const u8, expected: []const []const []const u8 }{
        .{ .exec = "viewer %f", .uris = &.{ "file:///tmp/a%20b", "file:///tmp/c" }, .expected = &.{ &.{ "viewer", "/tmp/a b" }, &.{ "viewer", "/tmp/c" } } },
        .{ .exec = "viewer %F", .uris = &.{ "file:///tmp/a", "https://x/y", "file:///tmp/c" }, .expected = &.{&.{ "viewer", "/tmp/a", "/tmp/c" }} },
        .{ .exec = "browser %u", .uris = &.{"https://example.com/?q=1&r=2"}, .expected = &.{&.{ "browser", "https://example.com/?q=1&r=2" }} },
        .{ .exec = "browser --new %U", .uris = &.{ "https://a", "mailto:b" }, .expected = &.{&.{ "browser", "--new", "https://a", "mailto:b" }} },
        .{ .exec = "plain", .uris = &.{"file:///tmp/x"}, .expected = &.{&.{ "plain", "/tmp/x" }} },
    };
    for (cases) |case| {
        // The programs need not exist, so the command line is used directly.
        const app = try App.fromCommandLine(std.testing.allocator, case.exec, "Case");
        defer app.unref();
        var remaining = case.uris;
        for (case.expected) |expected| {
            const args = try app.argvFor(a, &remaining);
            try std.testing.expectEqual(expected.len, args.len);
            for (expected, args) |want, got| try std.testing.expectEqualStrings(want, got);
        }
        try std.testing.expectEqual(@as(usize, 0), remaining.len);
    }
    try std.testing.expectEqualStrings("https", uriScheme("https://x").?);
    try std.testing.expect(uriScheme("/tmp/x") == null);
    try std.testing.expect(uriScheme("1abc:x") == null);
}
