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
const linux = std.os.linux;
const paths = @import("desktop-paths.zig");
const util = @import("desktop-util.zig");

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

    /// The command with field codes expanded and no files, split into arguments.
    pub fn argv(self: *const App, a: std.mem.Allocator) ![][:0]u8 {
        const command = self.exec orelse return error.MissingCommand;
        var expanded: std.ArrayList(u8) = .empty;
        defer expanded.deinit(a);
        var i: usize = 0;
        while (i < command.len) : (i += 1) {
            if (command[i] != '%' or i + 1 == command.len) {
                try expanded.append(a, command[i]);
                continue;
            }
            i += 1;
            switch (command[i]) {
                '%' => try expanded.append(a, '%'),
                'i' => if (self.icon) |icon| {
                    try expanded.appendSlice(a, "--icon ");
                    try shellQuote(a, &expanded, icon);
                },
                'c' => try shellQuote(a, &expanded, self.name),
                'k' => if (self.filename) |filename| try shellQuote(a, &expanded, filename),
                // No files or URIs are passed; deprecated and unknown codes expand to nothing.
                else => {},
            }
        }
        return shellParse(a, expanded.items);
    }

    /// Starts the application: D-Bus activation when the entry asks for it,
    /// otherwise its command, run in a terminal when Terminal is set.
    pub fn launch(self: *const App, gpa: std.mem.Allocator) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (self.dbus_activatable) if (busName(self.id)) |name| return activate(a, name);
        const directory = if (self.path) |value| (if (value.len > 0) value else null) else null;
        try spawn(a, try self.launchArgs(a), directory, self.filename);
    }

    /// The arguments `launch` executes, wrapped in a terminal when Terminal is set.
    pub fn launchArgs(self: *const App, a: std.mem.Allocator) ![][:0]u8 {
        const args = try self.argv(a);
        if (!self.terminal) return args;
        // GIO's terminal list does not consistently include Ghostty.
        const wrapped = try a.alloc([:0]u8, args.len + 2);
        wrapped[0] = try a.dupeSentinel(u8, "ghostty", 0);
        wrapped[1] = try a.dupeSentinel(u8, "-e", 0);
        @memcpy(wrapped[2..], args);
        return wrapped;
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

/// org.freedesktop.Application.Activate on the application's well-known name.
fn activate(a: std.mem.Allocator, name: []const u8) !void {
    const dbus = @import("dbus");
    const object = try a.alloc(u8, name.len + 1);
    object[0] = '/';
    for (name, object[1..]) |byte, *out| out.* = switch (byte) {
        '.' => '/',
        '-' => '_',
        else => byte,
    };
    const connection = try dbus.Connection.open(a, .session);
    defer connection.close();
    const platform_data: dbus.Dict([]const u8, dbus.Value) = .{ .entries = &.{} };
    const reply = try connection.callBlocking(.{ .destination = name, .path = object, .interface = "org.freedesktop.Application", .member = "Activate" }, .{platform_data}, 25000);
    reply.deinit();
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

/// Splits a command line as g_shell_parse_argv: blanks separate words, single
/// quotes are literal, double quotes allow \ before $ ` " \ and newline, a
/// backslash outside quotes escapes the next byte, and # starts a comment at
/// the beginning of a word. Nothing is expanded.
pub fn shellParse(a: std.mem.Allocator, command: []const u8) ![][:0]u8 {
    var words: std.ArrayList([:0]u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const byte = command[i];
        switch (byte) {
            ' ', '\t', '\n' => {
                if (in_word) {
                    try words.append(a, try word.toOwnedSliceSentinel(a, 0));
                    in_word = false;
                }
            },
            '#' => if (in_word) try word.append(a, byte) else {
                while (i < command.len and command[i] != '\n') i += 1;
            },
            '\\' => {
                in_word = true;
                if (i + 1 >= command.len) return error.InvalidCommand;
                i += 1;
                // A backslash-newline pair joins lines.
                if (command[i] != '\n') try word.append(a, command[i]);
            },
            '\'' => {
                in_word = true;
                const close = std.mem.indexOfScalarPos(u8, command, i + 1, '\'') orelse return error.InvalidCommand;
                try word.appendSlice(a, command[i + 1 .. close]);
                i = close;
            },
            '"' => {
                in_word = true;
                i += 1;
                while (true) : (i += 1) {
                    if (i >= command.len) return error.InvalidCommand;
                    switch (command[i]) {
                        '"' => break,
                        '\\' => if (i + 1 < command.len and std.mem.indexOfScalar(u8, "$`\"\\\n", command[i + 1]) != null) {
                            i += 1;
                            if (command[i] != '\n') try word.append(a, command[i]);
                        } else try word.append(a, '\\'),
                        else => |value| try word.append(a, value),
                    }
                }
            },
            else => {
                in_word = true;
                try word.append(a, byte);
            },
        }
    }
    if (in_word) try words.append(a, try word.toOwnedSliceSentinel(a, 0));
    if (words.items.len == 0) return error.EmptyCommand;
    return words.toOwnedSlice(a);
}

/// Appends `value` single-quoted for a shell, as g_shell_quote.
pub fn shellQuote(a: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(a, '\'');
    for (value) |byte| if (byte == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, byte);
    try out.append(a, '\'');
}

/// Runs `args` detached from this process, as g_spawn_async does without
/// G_SPAWN_DO_NOT_REAP_CHILD: an intermediate child forks the program and
/// exits, so the program is reparented and needs no reaping. Fails when the
/// program cannot be executed, which the program's process reports through a
/// close-on-exec pipe. Descriptors other than standard input, output and error
/// are not inherited.
pub fn spawn(a: std.mem.Allocator, args: []const [:0]const u8, directory: ?[]const u8, desktop_file: ?[]const u8) !void {
    if (args.len == 0) return error.EmptyCommand;
    // Everything the children use is prepared first: after fork they only make system calls.
    const argv = try a.allocSentinel(?[*:0]const u8, args.len, null);
    for (args, argv) |arg, *slot| slot.* = arg.ptr;
    var candidates: std.ArrayList([:0]const u8) = .empty;
    if (std.mem.indexOfScalar(u8, args[0], '/') != null) {
        try candidates.append(a, args[0]);
    } else {
        var search = std.mem.splitScalar(u8, util.env("PATH") orelse "/bin:/usr/bin", ':');
        while (search.next()) |dir| try candidates.append(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ if (dir.len == 0) "." else dir, args[0] }, 0));
    }
    const cwd = if (directory) |value| try a.dupeSentinel(u8, value, 0) else null;
    var environment: std.ArrayList(?[*:0]const u8) = .empty;
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        const text = std.mem.span(entry);
        if (std.mem.startsWith(u8, text, "GIO_LAUNCHED_DESKTOP_FILE")) continue;
        try environment.append(a, entry);
    }
    // GIO tells the program which desktop file launched it and its own process ID.
    var pid_variable = try a.allocSentinel(u8, "GIO_LAUNCHED_DESKTOP_FILE_PID=".len + 20, 0);
    @memcpy(pid_variable[0.."GIO_LAUNCHED_DESKTOP_FILE_PID=".len], "GIO_LAUNCHED_DESKTOP_FILE_PID=");
    if (desktop_file) |file| {
        try environment.append(a, (try std.fmt.allocPrintSentinel(a, "GIO_LAUNCHED_DESKTOP_FILE={s}", .{file}, 0)).ptr);
        try environment.append(a, pid_variable.ptr);
    }
    try environment.append(a, null);
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(environment.items.ptr);

    var report: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&report, .{ .CLOEXEC = true })) != .SUCCESS) return error.SpawnFailed;
    const forked = linux.fork();
    if (linux.errno(forked) != .SUCCESS) {
        _ = linux.close(report[0]);
        _ = linux.close(report[1]);
        return error.SpawnFailed;
    }
    if (forked == 0) {
        _ = linux.close(report[0]);
        const program = linux.fork();
        if (program != 0) linux.exit_group(if (linux.errno(program) == .SUCCESS) 0 else 1);
        // Only the report pipe and standard streams survive exec.
        _ = linux.close_range(3, std.math.maxInt(linux.fd_t), .{ .CLOEXEC = true, .UNSHARE = false });
        if (desktop_file != null) {
            var digits: [20]u8 = undefined;
            var value: usize = @intCast(linux.getpid());
            var start: usize = digits.len;
            while (true) {
                start -= 1;
                digits[start] = @intCast('0' + value % 10);
                value /= 10;
                if (value == 0) break;
            }
            const prefix = "GIO_LAUNCHED_DESKTOP_FILE_PID=".len;
            @memcpy(pid_variable[prefix..][0 .. digits.len - start], digits[start..]);
            pid_variable[prefix + digits.len - start] = 0;
        }
        var failure: linux.E = .NOENT;
        if (cwd) |path| if (linux.errno(linux.chdir(path)) != .SUCCESS) {
            failure = linux.errno(linux.chdir(path));
            _ = linux.write(report[1], std.mem.asBytes(&failure), @sizeOf(linux.E));
            linux.exit_group(127);
        };
        for (candidates.items) |candidate| {
            const result = linux.errno(linux.execve(candidate, argv, envp));
            // Like execvp, permission errors are remembered while the search continues.
            if (result == .ACCES or failure == .NOENT) failure = result;
        }
        _ = linux.write(report[1], std.mem.asBytes(&failure), @sizeOf(linux.E));
        linux.exit_group(127);
    }
    _ = linux.close(report[1]);
    defer _ = linux.close(report[0]);
    var status: i32 = 0;
    while (linux.errno(linux.wait4(@intCast(forked), &status, 0, null)) == .INTR) {}
    if (status != 0) return error.SpawnFailed;
    var failure: linux.E = .SUCCESS;
    while (true) {
        const got = linux.read(report[0], std.mem.asBytes(&failure), @sizeOf(linux.E));
        switch (linux.errno(got)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.SpawnFailed,
        }
        // End of file: exec succeeded and closed the pipe.
        if (got == 0) return;
        return switch (failure) {
            .NOENT, .NOTDIR => error.FileNotFound,
            .ACCES, .PERM => error.AccessDenied,
            else => error.SpawnFailed,
        };
    }
}

/// The directories searched for desktop files, highest priority first.
fn applicationDirectories(a: std.mem.Allocator) ![]const []const u8 {
    var directories: std.ArrayList([]const u8) = .empty;
    try directories.append(a, try std.fmt.allocPrint(a, "{s}/applications", .{paths.dataHome()}));
    const system = util.env("XDG_DATA_DIRS") orelse "";
    var dirs = std.mem.splitScalar(u8, if (system.len > 0) system else "/usr/local/share/:/usr/share/", ':');
    while (dirs.next()) |dir| if (dir.len > 0) {
        try directories.append(a, try std.fmt.allocPrint(a, "{s}/applications", .{std.mem.trimEnd(u8, dir, "/")}));
    };
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

test "key files, locales and command lines" {
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

    const words = try shellParse(a, "env 'a b' \"c \\\"d\\\" \\x\" e\\ f #comment\n g");
    const expected = [_][]const u8{ "env", "a b", "c \"d\" \\x", "e f", "g" };
    try std.testing.expectEqual(expected.len, words.len);
    for (expected, words) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectError(error.InvalidCommand, shellParse(a, "'unterminated"));
    try std.testing.expectError(error.EmptyCommand, shellParse(a, "  # only a comment"));
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

test "spawn reports programs that cannot run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try spawn(a, &.{ "true", "argument" }, null, null);
    try std.testing.expectError(error.FileNotFound, spawn(a, &.{"/nonexistent/desktop-appinfo-test"}, null, null));
    try std.testing.expectError(error.FileNotFound, spawn(a, &.{"desktop-appinfo-test-missing-program"}, null, null));
    try std.testing.expectError(error.FileNotFound, spawn(a, &.{"true"}, "/nonexistent/directory", null));
}

test "installed applications match GIO" {
    const glib = struct {
        extern fn g_app_info_get_all() ?*List;
        extern fn g_app_info_get_id(info: *anyopaque) ?[*:0]const u8;
        extern fn g_app_info_get_display_name(info: *anyopaque) [*:0]const u8;
        extern fn g_app_info_get_name(info: *anyopaque) [*:0]const u8;
        extern fn g_app_info_get_commandline(info: *anyopaque) ?[*:0]const u8;
        extern fn g_app_info_should_show(info: *anyopaque) c_int;
        extern fn g_app_info_get_icon(info: *anyopaque) ?*anyopaque;
        extern fn g_icon_to_string(icon: *anyopaque) ?[*:0]u8;
        extern fn g_desktop_app_info_get_filename(info: *anyopaque) ?[*:0]const u8;
        extern fn g_desktop_app_info_new(id: [*:0]const u8) ?*anyopaque;
        extern fn g_list_free_full(list: ?*List, free: *const fn (?*anyopaque) callconv(.c) void) void;
        extern fn g_object_unref(object: ?*anyopaque) callconv(.c) void;
        extern fn g_free(mem: ?*anyopaque) void;
        const List = extern struct { data: *anyopaque, next: ?*List, prev: ?*List };
    };
    const a = std.testing.allocator;
    const apps = try all(a);
    defer {
        for (apps) |app| app.unref();
        a.free(apps);
    }
    const list = glib.g_app_info_get_all();
    defer glib.g_list_free_full(list, &glib.g_object_unref);
    var count: usize = 0;
    var node = list;
    while (node) |item| : (node = item.next) {
        count += 1;
        const info = item.data;
        const id = std.mem.span(glib.g_app_info_get_id(info).?);
        const app = for (apps) |candidate| {
            if (std.mem.eql(u8, candidate.id, id)) break candidate;
        } else {
            std.debug.print("missing application {s}\n", .{id});
            return error.TestExpectedEqual;
        };
        errdefer std.debug.print("differs: {s}\n", .{id});
        try std.testing.expectEqualStrings(std.mem.span(glib.g_desktop_app_info_get_filename(info).?), app.filename.?);
        try std.testing.expectEqualStrings(std.mem.span(glib.g_app_info_get_name(info)), app.name);
        try std.testing.expectEqualStrings(std.mem.span(glib.g_app_info_get_display_name(info)), app.display_name);
        try std.testing.expectEqual(glib.g_app_info_should_show(info) != 0, app.shouldShow());
        if (glib.g_app_info_get_commandline(info)) |command| try std.testing.expectEqualStrings(std.mem.span(command), app.exec.?) else try std.testing.expect(app.exec == null);
        if (glib.g_app_info_get_icon(info)) |icon| {
            const text = glib.g_icon_to_string(icon).?;
            defer glib.g_free(text);
            try std.testing.expectEqualStrings(std.mem.span(text), app.icon.?);
        } else try std.testing.expect(app.icon == null);
        const found = lookup(a, id) orelse return error.TestExpectedEqual;
        defer found.unref();
        try std.testing.expectEqualStrings(app.filename.?, found.filename.?);
    }
    try std.testing.expectEqual(count, apps.len);
    try std.testing.expect(lookup(a, "desktop-appinfo-test-missing.desktop") == null);
    try std.testing.expect(glib.g_desktop_app_info_new("desktop-appinfo-test-missing.desktop") == null);
}
