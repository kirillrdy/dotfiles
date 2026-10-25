//! Exercise the native switcher in a private headless labwc session.
//! Usage: check-labwc-switcher --system SYSTEM --fixture FIXTURE [--wtype PATH]
const std = @import("std");
const u = @import("desktop-util.zig");
const A = u.Allocator;
const Options = struct { system: []const u8 = "", fixture: []const u8 = "", wtype: []const u8 = "wtype", bus: []const u8 = "dbus-run-session", inside: bool = false };
const Process = struct { id: std.posix.pid_t, done: bool = false, status: u32 = 0 };
const Runner = struct {
    a: A,
    root: []const u8,
    env: *std.process.Environ.Map,
    options: Options,
    processes: std.array_list.Managed(*Process),
    fn start(r: *Runner, argv: []const []const u8, log: []const u8) !*Process {
        var args = std.array_list.Managed([]const u8).init(r.a);
        try args.appendSlice(&.{ "sh", "-c", "log=$1; shift; exec \"$@\" >\"$log\" 2>&1", "--", try u.fmt(r.a, "{s}/{s}", .{ r.root, log }) });
        try args.appendSlice(argv);
        const child = try std.process.spawn(u.io, .{ .argv = args.items, .environ_map = r.env });
        const process = try r.a.create(Process);
        process.* = .{ .id = child.id.? };
        try r.processes.append(process);
        return process;
    }
    fn alive(_: *Runner, process: *Process) bool {
        if (process.done) return false;
        var status: c_int = 0;
        const result = u.libc.waitpid(process.id, &status, u.libc.WNOHANG);
        if (result == 0) return true;
        process.done = true;
        process.status = @bitCast(status);
        return false;
    }
    fn wait(r: *Runner, process: *Process, seconds: u64) !void {
        const timer = u.Timer.start();
        while (r.alive(process)) {
            if (timer.read() > seconds * std.time.ns_per_s) return error.ProcessTimeout;
            u.sleep(50 * std.time.ns_per_ms);
        }
    }
    fn terminate(r: *Runner, process: *Process) void {
        if (!r.alive(process)) return;
        std.posix.kill(process.id, std.posix.SIG.TERM) catch {};
        r.wait(process, 5) catch {
            std.posix.kill(process.id, std.posix.SIG.KILL) catch {};
            _ = u.libc.waitpid(process.id, null, 0);
            process.done = true;
        };
    }
    fn run(r: *Runner, argv: []const []const u8) !void {
        const args = try r.a.alloc([]const u8, argv.len + 2);
        args[0] = "timeout";
        args[1] = if (argv.len > 1 and std.mem.startsWith(u8, argv[1], "--config-file=")) "65" else "10";
        @memcpy(args[2..], argv);
        const result = try std.process.run(r.a, u.io, .{ .argv = args, .environ_map = r.env });
        if (argv.len > 1 and std.mem.startsWith(u8, argv[1], "--config-file=")) {
            try std.Io.File.stdout().writeStreamingAll(u.io, result.stdout);
        }
        if (result.term != .exited or result.term.exited != 0) {
            try std.Io.File.stderr().writeStreamingAll(u.io, result.stderr);
            return error.CommandFailed;
        }
    }
    fn focused(r: *Runner) ![]const u8 {
        var dir = try std.Io.Dir.openDirAbsolute(u.io, r.root, .{ .iterate = true });
        defer dir.close(u.io);
        var entries = dir.iterate();
        var newest: u64 = 0;
        var title: []const u8 = "";
        while (try entries.next(u.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "window-") or !std.mem.endsWith(u8, entry.name, ".log")) continue;
            const contents = try dir.readFileAlloc(u.io, entry.name, r.a, .limited(1024 * 1024));
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| {
                const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
                const stamp = std.fmt.parseInt(u64, line[0..space], 10) catch continue;
                if (stamp > newest) {
                    newest = stamp;
                    title = line[space + 1 ..];
                }
            }
        }
        return title;
    }
    fn expect(r: *Runner, title: []const u8) !void {
        const timer = u.Timer.start();
        while (!u.eq(try r.focused(), title)) {
            if (timer.read() > 8 * std.time.ns_per_s) {
                std.debug.print("Expected focus on {s}; got {s}\n", .{ title, try r.focused() });
                return error.WrongFocus;
            }
            u.sleep(50 * std.time.ns_per_ms);
        }
    }
    fn keys(r: *Runner, args: []const []const u8) !void {
        const argv = try r.a.alloc([]const u8, args.len + 1);
        argv[0] = r.options.wtype;
        @memcpy(argv[1..], args);
        try r.run(argv);
        u.sleep(200 * std.time.ns_per_ms);
    }
    fn pass(r: *Runner, message: []const u8) !void {
        try std.Io.File.stdout().writeStreamingAll(u.io, try u.fmt(r.a, "PASS {s}\n", .{message}));
    }
};
fn write(a: A, path: []const u8, data: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.cwd().createDirPath(u.io, parent);
    const file = try std.Io.Dir.createFileAbsolute(u.io, path, .{});
    defer file.close(u.io);
    try file.writeStreamingAll(u.io, data);
    _ = a;
}
fn inside(a: A, env: *std.process.Environ.Map, options: Options) !void {
    const runtime = env.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntime;
    const root = std.fs.path.dirname(runtime) orelse return error.InvalidRuntime;
    try env.put("WAYLAND_DISPLAY", "wayland-0");
    var r = Runner{ .a = a, .root = root, .env = env, .options = options, .processes = std.array_list.Managed(*Process).init(a) };
    defer {
        var i = r.processes.items.len;
        while (i > 0) {
            i -= 1;
            r.terminate(r.processes.items[i]);
        }
    }
    const compositor = try r.start(&.{ "labwc", "-C", try u.fmt(a, "{s}/labwc", .{env.get("XDG_CONFIG_HOME").?}), "-V" }, "labwc.log");
    const socket = try u.fmt(a, "{s}/wayland-0", .{runtime});
    const timer = u.Timer.start();
    while (!u.exists(socket)) {
        if (timer.read() > 8 * std.time.ns_per_s) return error.NoCompositorSocket;
        u.sleep(50 * std.time.ns_per_ms);
    }
    try r.run(&.{ "wlr-randr", "--output", "HEADLESS-1", "--custom-mode", "2880x1800", "--scale", "1.6666666667" });
    _ = try r.start(&.{ options.wtype, "-s", "55000" }, "keyboard-seat.log");
    u.sleep(200 * std.time.ns_per_ms);
    const titles = [_][]const u8{ "Browser 1", "Browser 2", "Terminal", "Files" };
    const apps = [_][]const u8{ "Browser", "Browser", "Terminal", "Files" };
    var windows: [4]*Process = undefined;
    for (titles, apps, 0..) |title, app, i| {
        windows[i] = try r.start(&.{ options.fixture, try u.fmt(a, "io.test.{s}", .{app}), title }, try u.fmt(a, "window-{d}.log", .{i}));
        try r.expect(title);
    }
    const held = try r.start(&.{ options.wtype, "-M", "alt", "-k", "Tab", "-k", "Tab", "-s", "1800", "-m", "alt" }, "keyboard.log");
    u.sleep(800 * std.time.ns_per_ms);
    if (!u.eq(try r.focused(), "Files")) return error.FocusBeforeAltRelease;
    try r.run(&.{ "grim", "-g", "350,280 1028x720", try u.fmt(a, "{s}/switcher.png", .{root}) });
    try r.wait(held, 5);
    try r.expect("Browser 2");
    try r.pass("application grouping and Alt release");
    try r.keys(&.{ "-M", "alt", "-M", "shift", "-k", "Tab", "-m", "shift", "-m", "alt" });
    try r.expect("Terminal");
    try r.pass("reverse cycling");
    try r.keys(&.{ "-M", "alt", "-k", "Tab", "-k", "Escape", "-m", "alt" });
    try r.expect("Terminal");
    try r.pass("Escape cancellation");
    try r.keys(&.{ "-M", "alt", "-k", "Tab", "-k", "Down", "-k", "Right", "-m", "alt" });
    try r.expect("Browser 1");
    try r.pass("application window navigation");
    try r.keys(&.{ "-M", "alt", "-k", "grave", "-m", "alt" });
    try r.expect("Browser 2");
    try r.pass("Alt-grave within an application");
    const closing = try r.start(&.{ options.wtype, "-M", "alt", "-k", "Tab", "-k", "Tab", "-s", "1800", "-m", "alt" }, "keyboard-close.log");
    u.sleep(600 * std.time.ns_per_ms);
    r.terminate(windows[3]);
    try r.wait(closing, 5);
    if (!r.alive(compositor)) return error.CompositorExited;
    try r.pass("closing a window during switching");
    r.terminate(windows[2]);
    r.terminate(windows[1]);
    try r.expect("Browser 1");
    try r.keys(&.{ "-M", "alt", "-k", "Tab", "-m", "alt" });
    try r.expect("Browser 1");
    try r.pass("single window");
    r.terminate(windows[0]);
    try r.keys(&.{ "-M", "alt", "-k", "Tab", "-m", "alt" });
    if (!r.alive(compositor)) return error.CompositorExited;
    try r.pass("no windows");
    const log = try u.read(a, try u.fmt(a, "{s}/labwc.log", .{root}));
    if (std.mem.indexOf(u8, log, "Invalid windowSwitcher") != null or std.mem.indexOf(u8, log, "[ERROR]") != null) {
        std.debug.print("{s}\n", .{log});
        return error.CompositorError;
    }
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    u.io = init.io;
    const args = try init.minimal.args.toSlice(a);
    var options = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (u.eq(args[i], "--inside")) {
            options.inside = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingValue;
        if (u.eq(args[i], "--system")) options.system = args[i + 1] else if (u.eq(args[i], "--fixture")) options.fixture = args[i + 1] else if (u.eq(args[i], "--wtype")) options.wtype = args[i + 1] else if (u.eq(args[i], "--dbus-run-session")) options.bus = args[i + 1] else return error.InvalidArgument;
        i += 1;
    }
    if (options.system.len == 0 or options.fixture.len == 0) return error.MissingArguments;
    options.system = try std.Io.Dir.cwd().realPathFileAlloc(u.io, options.system, a);
    var env = try init.minimal.environ.createMap(a);
    if (options.inside) return inside(a, &env, options);
    var random_id: u64 = undefined;
    u.io.random(std.mem.asBytes(&random_id));
    const root = try u.fmt(a, "/tmp/labwc-switcher-{x}", .{random_id});
    try std.Io.Dir.createDirAbsolute(u.io, root, .default_dir);
    const runtime = try u.fmt(a, "{s}/runtime", .{root});
    try std.Io.Dir.createDirAbsolute(u.io, runtime, @fromBackingInt(@intCast(0o700)));
    const config = try u.fmt(a, "{s}/config/labwc", .{root});
    try write(a, try u.fmt(a, "{s}/rc.xml", .{config}), try u.read(a, try u.fmt(a, "{s}/etc/xdg/labwc/rc.xml", .{options.system})));
    try write(a, try u.fmt(a, "{s}/autostart", .{config}), "");
    try write(a, try u.fmt(a, "{s}/environment", .{config}), "LABWC_UPDATE_ACTIVATION_ENV=false\n");
    for ([_][]const u8{ "Browser", "Terminal", "Files" }, [_][]const u8{ "firefox", "com.mitchellh.ghostty", "folder" }) |app, icon| try write(a, try u.fmt(a, "{s}/data/applications/io.test.{s}.desktop", .{ root, app }), try u.fmt(a, "[Desktop Entry]\nType=Application\nName={s}\nIcon={s}\nExec=true\n", .{ app, icon }));
    const bus = try u.fmt(a, "{s}/dbus.conf", .{root});
    try write(a, bus, try u.fmt(a, "<busconfig><type>session</type><listen>unix:tmpdir={s}</listen><policy context=\"default\"><allow send_destination=\"*\"/><allow receive_sender=\"*\"/><allow own=\"*\"/></policy></busconfig>", .{runtime}));
    for ([_][]const u8{ "DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "LABWC_PID" }) |name| _ = env.swapRemove(name);
    try env.put("XDG_RUNTIME_DIR", runtime);
    try env.put("XDG_CONFIG_HOME", try u.fmt(a, "{s}/config", .{root}));
    try env.put("XDG_DATA_HOME", try u.fmt(a, "{s}/data", .{root}));
    try env.put("XDG_DATA_DIRS", try u.fmt(a, "{s}/sw/share", .{options.system}));
    try env.put("XDG_CACHE_HOME", try u.fmt(a, "{s}/cache", .{root}));
    inline for (.{ .{ "WLR_BACKENDS", "headless" }, .{ "WLR_RENDERER", "pixman" }, .{ "WLR_HEADLESS_OUTPUTS", "1" }, .{ "LABWC_UPDATE_ACTIVATION_ENV", "false" }, .{ "XDG_CURRENT_DESKTOP", "labwc" }, .{ "NO_AT_BRIDGE", "1" }, .{ "GTK_USE_PORTAL", "0" }, .{ "GIO_USE_VFS", "local" } }) |pair| try env.put(pair[0], pair[1]);
    try env.put("PATH", try u.fmt(a, "{s}/sw/bin:{s}", .{ options.system, env.get("PATH") orelse "" }));
    try std.Io.File.stdout().writeStreamingAll(u.io, try u.fmt(a, "Test artifacts: {s}\nSystem: {s}\n", .{ root, options.system }));
    var runner = Runner{ .a = a, .root = root, .env = &env, .options = options, .processes = std.array_list.Managed(*Process).init(a) };
    const config_arg = try u.fmt(a, "--config-file={s}", .{bus});
    // Re-exec the compiled runner inside a private session bus.
    try runner.run(&.{ options.bus, config_arg, "--", try std.process.executablePathAlloc(u.io, a), "--system", options.system, "--fixture", options.fixture, "--wtype", options.wtype, "--inside" });
}
