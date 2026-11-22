//! Session shell. Compositor-specific operations stay behind Wayland protocols.
const std = @import("std");
const c = @import("desktop-glib.zig");
pub const libc = @import("desktop-libc.zig");
const panel = @import("desktop-panel.zig");
const wallpaper = @import("desktop-wallpaper.zig");
pub const notifications = @import("desktop-notifications.zig");
pub const osd = @import("desktop-osd.zig");
pub const polkit = @import("desktop-polkit.zig");
const overview = @import("desktop-overview.zig");
pub const settings = @import("desktop-settings.zig");
pub const window = @import("desktop-window.zig");
const collectors = @import("desktop-collectors.zig");
pub const widgets = @import("desktop-widgets.zig");
pub const idle = @import("desktop-idle.zig");
const device_service = @import("desktop-devices.zig");
pub const dbus = @import("dbus");
const loop = @import("desktop-dbus-loop.zig");
const shell_name = "org.dotfiles.Desktop";
const shell_path = "/org/dotfiles/Desktop";
const shell_xml = loop.commandXml(shell_name);
/// Cleared to leave the main loop: on SIGTERM/SIGINT, or when the notification name is lost.
var running = true;
var current: ?*Session = null;

const Session = struct {
    allocator: std.mem.Allocator,
    /// The shared session connection that owns org.dotfiles.Desktop.
    bus: *loop.Source,
    devices: ?*device_service.Service = null,
    device_subscription: device_service.Subscriber = undefined,
    device_subscribed: bool = false,
    panels: ?*panel.Service = null,
    background: ?*wallpaper.Service = null,
    notices: ?*notifications.Service = null,
    agent: ?polkit.Service = null,
    inactivity: ?*idle.Service = null,
    media: osd.Server,
    activities: overview.State = .{ .wallpaper = "" },
    dialogs: settings.Service,
    data: collectors.Service = undefined,
    data_started: bool = false,
    image: ?[:0]u8 = null,
    timer: c.guint = 0,
    serving: bool = false,
    stopping: bool = false,

    fn start(self: *Session, args: []const []const u8) !void {
        if (self.stopping) return error.SessionStopping;
        if (self.serving) return error.AlreadyRunning;
        if (args.len != 1 and args.len != 2 and args.len != 5) return error.InvalidServeArguments;
        if (libc.prctl(libc.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.PrctlFailed;
        self.image = try self.allocator.dupeSentinel(u8, args[0], 0);
        self.activities.wallpaper = self.image.?.ptr;
        var temporary = std.heap.ArenaAllocator.init(self.allocator);
        defer temporary.deinit();
        const alloc = temporary.allocator();
        const config = try alloc.dupeSentinel(u8, if (args.len > 1) args[1] else "/etc/xdg/desktop-panel/config.json", 0);
        self.background = try wallpaper.Service.create(self.allocator, self.image.?);
        self.devices = try device_service.Service.create(self.allocator);
        self.panels = try panel.Service.create(self.allocator, config, self.devices.?);
        self.notices = try notifications.Service.create(self.allocator);
        try self.media.start();
        self.media.connection = self.bus.connection;
        self.agent = polkit.Service.init(self.allocator) catch |err| blk: {
            std.log.warn("PolicyKit agent: {s}; will retry", .{@errorName(err)});
            break :blk null;
        };
        self.data = .{ .allocator = self.allocator, .devices = self.devices.?, .panel = self.panels.? };
        self.data.start();
        self.data_started = true;
        self.inactivity = try idle.Service.create(self.allocator, .{ .session_inhibit = true, .wallpaper = self.image.? });
        self.device_subscription = .{ .context = self, .changed = &devicesChanged };
        self.devices.?.subscribe(&self.device_subscription);
        self.device_subscribed = true;
        devicesChanged(self, self.devices.?, .audio);
        self.serving = true;
        current = self;
        widgets.refresh_source = &refresh;
        self.timer = c.g_timeout_add_seconds(5, &maintain, self);
    }

    fn devicesChanged(ptr: ?*anyopaque, source: *device_service.Service, event: device_service.Event) void {
        if (event != .audio) return;
        const self: *Session = @ptrCast(@alignCast(ptr));
        const inactivity = self.inactivity orelse return;
        const audio_service = source.audio_service orelse {
            inactivity.setAudioInhibited(false);
            return;
        };
        inactivity.setAudioInhibited(audio_service.activeRecording());
    }

    fn maintain(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self: *Session = @ptrCast(@alignCast(ptr));
        self.dialogs.reap();
        if (self.agent == null) self.agent = polkit.Service.init(self.allocator) catch null;
        return 1;
    }

    fn deinit(self: *Session) void {
        self.stopping = true;
        current = null;
        widgets.refresh_source = null;
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        if (self.device_subscribed) self.devices.?.unsubscribe(&self.device_subscription);
        self.device_subscribed = false;
        if (self.inactivity) |inactivity| inactivity.destroy();
        if (self.data_started) self.data.deinit();
        self.dialogs.deinit();
        overview.deinit(&self.activities);
        self.media.deinit();
        if (self.agent) |*agent| agent.deinit();
        if (self.panels) |panels| panels.destroy();
        if (self.devices) |devices| devices.destroy();
        if (self.notices) |notices| notices.destroy();
        if (self.background) |background| background.destroy();
        // Drain cancelled widget reads while their reference-counted states survive.
        while (c.g_main_context_iteration(null, 0) != 0) {}
        if (self.image) |image| self.allocator.free(image);
    }
};
fn refresh(kind: []const u8) void {
    if (current) |session| session.data.refresh(kind);
}
fn quit(_: c.gpointer) callconv(.c) c.gboolean {
    running = false;
    return 1;
}
fn stop() void {
    running = false;
}
/// Runs a command forwarded by another `desktop-zig` invocation.
fn command(ptr: ?*anyopaque, message: *const dbus.Message) void {
    const self: *Session = @ptrCast(@alignCast(ptr));
    const connection = self.bus.connection;
    const args = message.read(struct { []const []const u8 }) catch return connection.replyError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Expected (as)") catch {};
    dispatch(self, args[0]) catch |err| return connection.replyError(message, shell_name ++ ".Error.Failed", @errorName(err)) catch {};
    connection.reply(message, .{}) catch {};
}
fn forward(a: std.mem.Allocator, args: []const []const u8) !void {
    return loop.forwardCommand(a, "desktop-zig", shell_name, shell_path, args);
}
fn dispatch(self: *Session, args: []const []const u8) !void {
    if (self.stopping) return error.SessionStopping;
    if (args.len == 0) return error.ExpectedCommand;
    const verb = args[0];
    if (std.mem.eql(u8, verb, "serve")) return self.start(args[1..]);
    if (!self.serving) return error.SessionNotRunning;
    if (std.mem.eql(u8, verb, "overview") and args.len == 1) {
        overview.activate(self.allocator, &self.activities);
    } else if (std.mem.eql(u8, verb, "overview-corner") and args.len == 1) {
        overview.activateCorner(self.allocator, &self.activities);
    } else if (std.mem.eql(u8, verb, "settings") and (args.len == 1 or args.len == 2)) {
        const mode: settings.Mode = if (args.len == 1)
            .network
        else if (std.mem.eql(u8, args[1], "sound"))
            .sound
        else if (std.mem.eql(u8, args[1], "network"))
            .network
        else
            return error.InvalidSettingsMode;
        try self.dialogs.show(mode);
    } else if (std.mem.eql(u8, verb, "refresh") and args.len == 2) {
        if (!panel_data.isUsage(args[1]) and !std.mem.eql(u8, args[1], "status")) return error.InvalidSource;
        self.data.refresh(args[1]);
    } else if (std.mem.eql(u8, verb, "ping") and args.len == 1) {
        return;
    } else if (osd.parseCommand(args)) |work| {
        if (!self.media.enqueue(work)) return error.QueueFull;
    } else return error.InvalidCommand;
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    try @import("desktop-runtime.zig").setup(a);
    @import("desktop-util.zig").io = init.io;
    const arguments = init.arena.allocator();
    var args = try init.minimal.args.toSlice(arguments);
    var managed_session = false;
    var compositor: ?*@import("desktop-compositor.zig").Handle = null;
    @import("desktop-icons.zig").init(a);
    defer {
        if (compositor) |handle| handle.stop();
        while (c.g_main_context_iteration(null, 0) != 0) {}
        @import("desktop-switcher.zig").deinit(a);
        window.deinit();
        @import("desktop-icons.zig").deinit();
        @import("desktop-gsettings.zig").deinit();
    }
    defer if (managed_session) sessionControl(a, init.io, &.{ "systemctl", "--user", "stop", "desktop-session.target" }) catch {};
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "compositor") or std.mem.eql(u8, args[1], "compositor-only"))) {
        compositor = try @import("desktop-compositor.zig").Handle.start(a, if (std.mem.eql(u8, args[1], "compositor")) .session else .headless);
        if (std.mem.eql(u8, args[1], "compositor-only")) {
            compositor.?.wait();
            compositor = null;
            return;
        }
        if (libc.getenv("DESKTOP_SESSION_MANAGED") != null) {
            try sessionControl(a, init.io, &.{ "systemctl", "--user", "import-environment", "WAYLAND_DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "XDG_SESSION_TYPE", "XDG_SESSION_ID", "PATH", "DISPLAY", "XCURSOR_THEME", "XCURSOR_SIZE" });
            try sessionControl(a, init.io, &.{ "systemctl", "--user", "start", "desktop-session.target" });
            managed_session = true;
        }
        const forwarded = try arguments.dupe([:0]const u8, args);
        forwarded[1] = "serve";
        args = forwarded;
    }
    const name = std.fs.path.basename(args[0]);
    // Executable aliases implement the portal and SSH askpass protocols.
    if (std.mem.eql(u8, name, "xdg-desktop-portal")) return @import("desktop-portal.zig").run(a);
    if (std.mem.eql(u8, name, "desktop-askpass")) return helperStatus(try @import("desktop-askpass.zig").runArgs(init, args));
    if (std.mem.eql(u8, name, "grim") or std.mem.eql(u8, name, "slurp")) {
        const forwarded = try arguments.dupe([]const u8, args);
        forwarded[0] = name;
        return helperStatus(try @import("desktop-screenshot.zig").runArgs(init, forwarded));
    }
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help")) {
        std.debug.print("Usage: desktop-zig compositor WALLPAPER\n       desktop-zig dm | greeter\n       desktop-zig serve WALLPAPER [PANEL_CONFIG]\n       desktop-zig overview | settings sound|network | volume up|down|mute\n       desktop-zig microphone mute | brightness up|down | refresh codex|claude|antigravity|status | ping\n       desktop-zig lock [--daemonize]\n       desktop-zig output --output NAME --scale SCALE\n       desktop-zig secrets | secrets-login | secrets-import\n       desktop-zig battery-monitor | portal | askpass|power|screenshot [ARGS...]\n", .{});
        if (args.len < 2) return error.ExpectedCommand;
        return;
    }
    if (std.mem.eql(u8, args[1], "dm")) {
        if (args.len != 2) return error.InvalidDmArguments;
        return @import("desktop-dm.zig").run(a);
    }
    if (std.mem.eql(u8, args[1], "greeter")) {
        if (args.len != 2) return error.InvalidGreeterArguments;
        return @import("desktop-greeter.zig").run(a);
    }
    if (std.mem.eql(u8, args[1], "secrets-import")) {
        if (args.len != 2) return error.InvalidSecretsArguments;
        return @import("desktop-secrets.zig").runImport(a);
    }
    if (std.mem.eql(u8, args[1], "secrets")) {
        if (args.len != 2) return error.InvalidSecretsArguments;
        return @import("desktop-secrets.zig").run(a);
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
        return @import("desktop-battery-monitor.zig").run(a);
    }
    if (std.mem.eql(u8, args[1], "portal")) return @import("desktop-portal.zig").run(a);
    if (std.mem.eql(u8, args[1], "power")) return @import("desktop-power.zig").runArgs(init, args[1..]);
    if (std.mem.eql(u8, args[1], "askpass")) return helperStatus(try @import("desktop-askpass.zig").runArgs(init, args[1..]));
    if (std.mem.eql(u8, args[1], "screenshot")) return helperStatus(try @import("desktop-screenshot.zig").runArgs(init, args[1..]));
    if (std.mem.eql(u8, args[1], "output")) return @import("desktop-output.zig").run(a, args[2..]);
    if (std.mem.eql(u8, args[1], "lock")) return @import("desktop-lock.zig").run(a, args[2..]);
    // Every command but serve goes to the running shell.
    if (!std.mem.eql(u8, args[1], "serve")) return forward(a, args[1..]);
    const bus = loop.acquire(a, .session) catch return error.NoSessionBus;
    defer loop.release(bus);
    // A second serve must not create another shell: forwarded, the running one rejects it.
    if ((bus.connection.requestName(shell_name, 4) catch return error.NoSessionBus) != 1) return forward(a, args[1..]);
    var introspection = try dbus.Introspection.parse(a, shell_xml);
    defer introspection.deinit();
    var session = Session{ .allocator = a, .bus = bus, .media = .init(a), .dialogs = .{ .allocator = a } };
    defer session.deinit();
    const exported = try bus.connection.exportObject(shell_path, &introspection.interfaces[0], &command, null, &session);
    defer bus.connection.unregister(exported);
    notifications.on_lost = &stop;
    const term = c.g_unix_signal_add(c.SIGTERM, &quit, null);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &quit, null);
    defer _ = c.g_source_remove(term);
    defer _ = c.g_source_remove(interrupt);
    try dispatch(&session, args[1..]);
    while (running and !bus.connection.closed) _ = c.g_main_context_iteration(null, 1);
    if (running) return error.SessionBusDisconnected;
    if (session.serving and !session.notices.?.isOwned()) return error.NotificationNameUnavailable;
}
fn sessionControl(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const current_environment: std.process.Environ = .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    var environment = try current_environment.createMap(a);
    defer environment.deinit();
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = &environment, .stdin = .ignore, .stdout = .ignore, .stderr = .inherit });
    if (!(try child.wait(io)).success()) return error.SessionControlFailed;
}
fn helperStatus(status: u8) void {
    if (status != 0) std.process.exit(status);
}

// Shared production namespace for isolated protocol and lifecycle clients.
pub const glib = @import("desktop-glib.zig");
pub const paths = @import("desktop-paths.zig");
pub const appinfo = @import("desktop-appinfo.zig");
pub const capture = @import("desktop-capture.zig");
pub const decode = @import("desktop-decode.zig");
pub const png = @import("desktop-png.zig");
pub const power = @import("desktop-power.zig");
pub const secrets = @import("desktop-secrets.zig");
pub const portal = @import("desktop-portal.zig");
pub const network = @import("desktop-network.zig");
pub const audio = @import("desktop-audio.zig");
pub const audio_pod = @import("desktop-audio-pod.zig");
pub const battery = @import("desktop-battery.zig");
pub const battery_monitor = @import("desktop-battery-monitor.zig");
pub const backlight = @import("desktop-backlight.zig");
pub const wayland = @import("desktop-wayland-client.zig");
pub const quick = @import("desktop-quick-settings.zig");
pub const panel_data = @import("desktop-panel-data.zig");
pub const askpass = @import("desktop-askpass.zig");
pub const screenshot = @import("desktop-screenshot.zig");
pub const output = @import("desktop-output.zig");
pub const lock = @import("desktop-lock.zig");
pub const auth = @import("desktop-lock-auth.zig");
pub const apps = @import("desktop-apps.zig");
pub const dash_view = @import("desktop-dash-view.zig");
pub const chooser = @import("desktop-portal-file-chooser.zig");
pub const util = @import("desktop-util.zig");
pub const icons = @import("desktop-icons.zig");
pub const gsettings = @import("desktop-gsettings.zig");
pub const posix = @import("posix");
pub const pipewire = @import("pipewire");
pub const network_editor = @import("desktop-network-editor.zig");
pub const session_actions = @import("desktop-session.zig");
pub const commands = @import("desktop-command.zig");
pub const dbus_loop = @import("desktop-dbus-loop.zig");
pub const dbus_text = @import("desktop-dbus-text.zig");
