//! Session shell. Compositor-specific operations stay behind Wayland protocols.
const std = @import("std");
const c = @import("desktop-gtk.zig");
pub const libc = @import("desktop-libc.zig");
const panel = @import("desktop-panel.zig");
pub const wallpaper = @import("desktop-wallpaper.zig");
const notifications = @import("desktop-notifications.zig");
pub const osd = @import("desktop-osd.zig");
pub const polkit = @import("desktop-polkit.zig");
const overview = @import("desktop-overview.zig");
pub const settings = @import("desktop-settings.zig");
const collectors = @import("desktop-collectors.zig");
pub const widgets = @import("desktop-widgets.zig");
pub const idle = @import("desktop-idle.zig");
const a = std.heap.page_allocator;
comptime {
    _ = @import("desktop-protocols.zig");
}
var current: ?*Session = null;

const Session = struct {
    app: *c.GtkApplication,
    panels: ?*panel.Service = null,
    background: ?*wallpaper.Service = null,
    notices: ?*notifications.Service = null,
    agent: ?polkit.Service = null,
    inactivity: ?*idle.Service = null,
    media: osd.Server = .{},
    activities: overview.State = .{ .wallpaper = "" },
    dialogs: settings.Service = .{},
    data: collectors.Service = undefined,
    image: ?[:0]u8 = null,
    timer: c.guint = 0,
    serving: bool = false,
    stopping: bool = false,

    fn start(self: *Session, args: []const []const u8) !void {
        if (self.stopping) return error.SessionStopping;
        if (self.serving) return error.AlreadyRunning;
        if (args.len != 1 and args.len != 5) return error.InvalidServeArguments;
        if (c.gtk_layer_is_supported() == 0) return error.LayerShellUnavailable;
        if (libc.prctl(libc.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.PrctlFailed;
        self.image = try a.dupeSentinel(u8, args[0], 0);
        self.activities.wallpaper = self.image.?.ptr;
        var temporary = std.heap.ArenaAllocator.init(a);
        defer temporary.deinit();
        const alloc = temporary.allocator();
        const config = try alloc.dupeSentinel(u8, if (args.len == 5) args[1] else "/etc/xdg/desktop-panel/config.json", 0);
        const panel_style = try alloc.dupeSentinel(u8, if (args.len == 5) args[2] else "/etc/xdg/desktop-panel/style.css", 0);
        const notice_style = try alloc.dupeSentinel(u8, if (args.len == 5) args[3] else "/etc/xdg/desktop-notifications/style.css", 0);
        const osd_style = try alloc.dupeSentinel(u8, if (args.len == 5) args[4] else "/etc/xdg/desktop-osd/style.css", 0);
        self.background = try wallpaper.Service.create(self.image.?);
        self.panels = try panel.Service.create(config, panel_style);
        self.notices = try notifications.Service.create(notice_style);
        try self.media.start(osd_style);
        self.media.connection = c.g_application_get_dbus_connection(@ptrCast(self.app));
        self.agent = polkit.Service.init() catch |err| blk: {
            std.log.warn("PolicyKit agent: {s}; will retry", .{@errorName(err)});
            break :blk null;
        };
        self.data = .{ .panel = self.panels.?, .icon = if (c.g_getenv("DESKTOP_CODEX_ICON")) |icon| std.mem.span(icon) else "" };
        self.data.start();
        self.inactivity = try idle.Service.create(.{});
        self.serving = true;
        current = self;
        widgets.refresh_source = &refresh;
        self.timer = c.g_timeout_add_seconds(5, &maintain, self);
        c.g_application_hold(@ptrCast(self.app));
    }

    fn maintain(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self: *Session = @ptrCast(@alignCast(ptr));
        self.dialogs.reap();
        if (self.agent == null) self.agent = polkit.Service.init() catch null;
        return 1;
    }

    fn deinit(self: *Session) void {
        self.stopping = true;
        current = null;
        widgets.refresh_source = null;
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        if (self.inactivity) |inactivity| inactivity.destroy();
        if (self.serving) self.data.deinit();
        self.dialogs.deinit();
        overview.deinit(&self.activities);
        self.media.deinit();
        if (self.agent) |*agent| agent.deinit();
        if (self.panels) |panels| panels.destroy();
        if (self.notices) |notices| notices.destroy();
        if (self.background) |background| background.destroy();
        // Drain cancelled widget reads while their reference-counted states survive.
        while (c.g_main_context_iteration(null, 0) != 0) {}
        if (self.image) |image| a.free(image);
    }
};
fn refresh(kind: []const u8) void {
    if (current) |session| session.data.refresh(kind);
}
fn quit(ptr: c.gpointer) callconv(.c) c.gboolean {
    c.g_application_quit(@ptrCast(@alignCast(ptr)));
    return 1;
}
fn commandLine(_: *c.GApplication, command: *c.GApplicationCommandLine, ptr: c.gpointer) callconv(.c) c_int {
    const self: *Session = @ptrCast(@alignCast(ptr));
    var count: c_int = 0;
    const argv = c.g_application_command_line_get_arguments(command, &count);
    defer c.g_strfreev(argv);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const args = arena.allocator().alloc([]const u8, @intCast(count)) catch return 1;
    for (args, 0..) |*arg, i| arg.* = std.mem.span(argv[i]);
    dispatch(self, args[1..]) catch |err| {
        c.g_application_command_line_printerr(command, "desktop-zig: %s\n", @as([*:0]const u8, @errorName(err)));
        return 1;
    };
    return 0;
}
fn dispatch(self: *Session, args: []const []const u8) !void {
    if (self.stopping) return error.SessionStopping;
    if (args.len == 0) return error.ExpectedCommand;
    const verb = args[0];
    if (std.mem.eql(u8, verb, "serve")) return self.start(args[1..]);
    if (!self.serving) return error.SessionNotRunning;
    if (std.mem.eql(u8, verb, "overview") and args.len == 1) {
        overview.activate(self.app, &self.activities);
    } else if (std.mem.eql(u8, verb, "settings") and args.len == 2) {
        const mode: settings.Mode = if (std.mem.eql(u8, args[1], "sound"))
            .sound
        else if (std.mem.eql(u8, args[1], "network"))
            .network
        else
            return error.InvalidSettingsMode;
        try self.dialogs.show(self.app, mode);
    } else if (std.mem.eql(u8, verb, "refresh") and args.len == 2) {
        if (!std.mem.eql(u8, args[1], "codex") and !std.mem.eql(u8, args[1], "status")) return error.InvalidSource;
        self.data.refresh(args[1]);
    } else if (std.mem.eql(u8, verb, "ping") and args.len == 1) {
        return;
    } else if (osd.parseCommand(args)) |work| {
        if (!self.media.enqueue(work)) return error.QueueFull;
    } else return error.InvalidCommand;
}

pub fn main(init: std.process.Init) !void {
    try @import("desktop-runtime.zig").setup(a);
    @import("desktop-util.zig").io = init.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var args = try init.minimal.args.toSlice(arena.allocator());
    var managed_session = false;
    var compositor: ?*@import("desktop-compositor.zig").Handle = null;
    defer if (compositor) |handle| handle.stop();
    defer if (managed_session) sessionControl(init.io, &.{ "systemctl", "--user", "stop", "desktop-session.target" }) catch {};
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "compositor") or std.mem.eql(u8, args[1], "compositor-only"))) {
        compositor = try @import("desktop-compositor.zig").Handle.start(std.mem.eql(u8, args[1], "compositor"));
        if (std.mem.eql(u8, args[1], "compositor-only")) {
            compositor.?.wait();
            compositor = null;
            return;
        }
        if (libc.getenv("DESKTOP_SESSION_MANAGED") != null) {
            try sessionControl(init.io, &.{ "systemctl", "--user", "import-environment", "WAYLAND_DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "XDG_SESSION_TYPE", "XDG_SESSION_ID", "PATH", "DISPLAY", "XCURSOR_THEME", "XCURSOR_SIZE" });
            try sessionControl(init.io, &.{ "systemctl", "--user", "start", "desktop-session.target" });
            managed_session = true;
        }
        const forwarded = try arena.allocator().dupe([:0]const u8, args);
        forwarded[1] = "serve";
        args = forwarded;
    }
    const name = std.fs.path.basename(args[0]);
    // Executable aliases implement the portal and SSH askpass protocols.
    if (std.mem.eql(u8, name, "xdg-desktop-portal")) return @import("desktop-portal.zig").run();
    if (std.mem.eql(u8, name, "desktop-askpass")) return helperStatus(try @import("desktop-askpass.zig").runArgs(init, args));
    if (std.mem.eql(u8, name, "grim") or std.mem.eql(u8, name, "slurp")) {
        const forwarded = try arena.allocator().dupe([]const u8, args);
        forwarded[0] = name;
        return helperStatus(try @import("desktop-screenshot.zig").runArgs(init, forwarded));
    }
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help")) {
        std.debug.print("Usage: desktop-zig compositor WALLPAPER\n       desktop-zig serve WALLPAPER [PANEL_CONFIG PANEL_STYLE NOTIFICATIONS_STYLE OSD_STYLE]\n       desktop-zig overview | settings sound|network | volume up|down|mute\n       desktop-zig microphone mute | brightness up|down | refresh codex|status | ping\n       desktop-zig lock [--daemonize]\n       desktop-zig output --output NAME --scale SCALE\n       desktop-zig secrets | secrets-login | secrets-import\n       desktop-zig battery-monitor | portal | askpass|power|screenshot [ARGS...]\n", .{});
        if (args.len < 2) return error.ExpectedCommand;
        return;
    }
    if (std.mem.eql(u8, args[1], "secrets-import")) {
        if (args.len != 2) return error.InvalidSecretsArguments;
        return @import("desktop-secrets.zig").runImport();
    }
    if (std.mem.eql(u8, args[1], "secrets")) {
        if (args.len != 2) return error.InvalidSecretsArguments;
        return @import("desktop-secrets.zig").run();
    }
    if (std.mem.eql(u8, args[1], "secrets-login")) {
        if (args.len != 2) return error.InvalidSecretsArguments;
        if (libc.prctl(libc.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.PrctlFailed;
        var password: [4097]u8 = undefined;
        defer std.crypto.secureZero(u8, &password);
        var length: usize = 0;
        while (length < password.len) {
            const n = libc.read(0, password[length..].ptr, password.len - length);
            if (n < 0 and libc.__errno_location().* == libc.EINTR) continue;
            if (n < 0) return error.ReadPassword;
            if (n == 0) break;
            length += @intCast(n);
        }
        if (length == 0 or length > 4096) return error.InvalidPassword;
        return @import("desktop-secrets.zig").loginUnlock(password[0..length]);
    }
    if (std.mem.eql(u8, args[1], "battery-monitor")) {
        if (args.len != 2) return error.InvalidBatteryMonitorArguments;
        return @import("desktop-battery-monitor.zig").run();
    }
    if (std.mem.eql(u8, args[1], "portal")) return @import("desktop-portal.zig").run();
    if (std.mem.eql(u8, args[1], "power")) return @import("desktop-power.zig").runArgs(init, args[1..]);
    if (std.mem.eql(u8, args[1], "askpass")) return helperStatus(try @import("desktop-askpass.zig").runArgs(init, args[1..]));
    if (std.mem.eql(u8, args[1], "screenshot")) return helperStatus(try @import("desktop-screenshot.zig").runArgs(init, args[1..]));
    if (std.mem.eql(u8, args[1], "output")) return @import("desktop-output.zig").run(args[2..]);
    if (std.mem.eql(u8, args[1], "lock")) return @import("desktop-lock.zig").run(args[2..]);
    if (!std.mem.eql(u8, args[1], "serve")) try requireSession();
    _ = c.g_setenv("GDK_BACKEND", "wayland", 1);
    const app = c.gtk_application_new("org.dotfiles.Desktop", c.G_APPLICATION_HANDLES_COMMAND_LINE).?;
    defer c.g_object_unref(app);
    var session = Session{ .app = app };
    defer session.deinit();
    defer @import("desktop-switcher.zig").deinit();
    _ = c.g_signal_connect_data(app, "command-line", @ptrCast(&commandLine), &session, null, 0);
    const term = c.g_unix_signal_add(c.SIGTERM, &quit, app);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &quit, app);
    defer _ = c.g_source_remove(term);
    defer _ = c.g_source_remove(interrupt);
    const argv = try arena.allocator().allocSentinel(?[*:0]const u8, args.len, null);
    for (args, 0..) |arg, i| argv[i] = (try arena.allocator().dupeSentinel(u8, arg, 0)).ptr;
    const status = c.g_application_run(@ptrCast(app), @intCast(args.len), @ptrCast(argv.ptr));
    if (status != 0) return error.CommandFailed;
    if (session.serving and !session.notices.?.isOwned()) return error.NotificationNameUnavailable;
}
fn sessionControl(io: std.Io, argv: []const []const u8) !void {
    const current_environment: std.process.Environ = .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    var environment = try current_environment.createMap(a);
    defer environment.deinit();
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = &environment, .stdin = .ignore, .stdout = .ignore, .stderr = .inherit });
    if (!(try child.wait(io)).success()) return error.SessionControlFailed;
}
fn helperStatus(status: u8) void {
    if (status != 0) std.process.exit(status);
}

// A command client must never compete with the daemon for its well-known name.
fn requireSession() !void {
    const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return error.NoSessionBus;
    defer c.g_object_unref(bus);
    const reply = c.g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", c.g_variant_new("(s)", @as([*:0]const u8, "org.dotfiles.Desktop")), null, c.G_DBUS_CALL_FLAGS_NONE, 3000, null, null) orelse return error.NoSessionBus;
    defer c.g_variant_unref(reply);
    const owned = c.g_variant_get_child_value(reply, 0);
    defer c.g_variant_unref(owned);
    if (c.g_variant_get_boolean(owned) == 0) return error.SessionNotRunning;
}

// Shared production namespace for isolated protocol and lifecycle clients.
pub const gtk = @import("desktop-gtk.zig");
pub const capture = @import("desktop-capture.zig");
pub const runtime = @import("desktop-runtime.zig");
pub const power = @import("desktop-power.zig");
pub const secrets = @import("desktop-secrets.zig");
pub const portal = @import("desktop-portal.zig");
pub const network = @import("desktop-network.zig");
pub const network_api = @import("desktop-network-api.zig");
pub const audio = @import("desktop-audio.zig");
pub const audio_pod = @import("desktop-audio-pod.zig");
pub const battery = @import("desktop-battery.zig");
pub const battery_monitor = @import("desktop-battery-monitor.zig");
pub const backlight = @import("desktop-backlight.zig");
pub const protocols = @import("desktop-protocols.zig");
pub const quick = @import("desktop-quick-settings.zig");
pub const panel_data = @import("waybar-panel.zig");
pub const askpass = @import("desktop-askpass.zig");
pub const screenshot = @import("desktop-screenshot.zig");
pub const output = @import("desktop-output.zig");
pub const lock = @import("desktop-lock.zig");
pub const auth = @import("desktop-lock-auth.zig");
pub const apps = @import("desktop-apps.zig");
pub const http = @import("desktop-http.zig");
pub const virtual_pointer = @import("desktop-virtual-pointer.zig");
pub const printing = @import("desktop-portal-print.zig");
pub const chooser = @import("desktop-portal-file-chooser.zig");
pub const util = @import("desktop-util.zig");
pub const posix = @import("posix");
pub const pipewire = @import("pipewire");

test {
    _ = @import("desktop-tests.zig");
}

pub const network_editor = @import("desktop-network-editor.zig");

pub const session_actions = @import("desktop-session.zig");
