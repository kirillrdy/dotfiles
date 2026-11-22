//! Child processes in Zig: command-line parsing and quoting as GLib's shell
//! helpers, starting programs with exec failures reported to the caller, and
//! watching children on the main loop through a pidfd, as GSubprocess did.
const std = @import("std");
const linux = std.os.linux;
const util = @import("desktop-util.zig");

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

pub const Options = struct {
    /// Working directory for the program.
    directory: ?[]const u8 = null,
    /// Entries added to the environment, replacing inherited ones of the same name.
    environment: []const [:0]const u8 = &.{},
    /// Discard standard output.
    silence_stdout: bool = false,
    /// Collect standard error for the result.
    capture_stderr: bool = false,
    /// Descriptors handed to the child at the given numbers, which must be 3 or more.
    fds: []const Mapping = &.{},
    /// An environment variable set to the program's own process ID, as GIO
    /// sets GIO_LAUNCHED_DESKTOP_FILE_PID.
    pid_variable: ?[]const u8 = null,

    pub const Mapping = struct { source: linux.fd_t, target: linux.fd_t };
};

pub const SpawnError = error{ FileNotFound, AccessDenied, SpawnFailed, EmptyCommand, OutOfMemory };

/// Prepared exec state: everything the child needs, built before fork so the
/// child only makes system calls.
const Exec = struct {
    argv: [*:null]const ?[*:0]const u8,
    candidates: []const [:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: ?[:0]const u8,
    options: Options,
    /// "NAME=" followed by room for the program's process ID, filled in by the child.
    pid_entry: ?[]u8 = null,

    fn prepare(a: std.mem.Allocator, args: []const [:0]const u8, options: Options) !Exec {
        if (args.len == 0) return error.EmptyCommand;
        const argv = try a.allocSentinel(?[*:0]const u8, args.len, null);
        for (args, argv) |arg, *slot| slot.* = arg.ptr;
        var candidates: std.ArrayList([:0]const u8) = .empty;
        if (std.mem.indexOfScalar(u8, args[0], '/') != null) {
            try candidates.append(a, args[0]);
        } else {
            var search = std.mem.splitScalar(u8, util.env("PATH") orelse "/bin:/usr/bin", ':');
            while (search.next()) |dir| try candidates.append(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ if (dir.len == 0) "." else dir, args[0] }, 0));
        }
        var environment: std.ArrayList(?[*:0]const u8) = .empty;
        var index: usize = 0;
        while (std.c.environ[index]) |entry| : (index += 1) {
            const text = std.mem.span(entry);
            const replaced = for (options.environment) |extra| {
                const key = extra[0 .. (std.mem.indexOfScalar(u8, extra, '=') orelse extra.len) + 1];
                if (std.mem.startsWith(u8, text, key)) break true;
            } else false;
            if (!replaced) try environment.append(a, entry);
        }
        for (options.environment) |extra| try environment.append(a, extra.ptr);
        var pid_entry: ?[]u8 = null;
        if (options.pid_variable) |name| {
            const entry = try a.allocSentinel(u8, name.len + 1 + 20, 0);
            @memcpy(entry[0..name.len], name);
            entry[name.len] = '=';
            entry[name.len + 1] = 0;
            try environment.append(a, entry.ptr);
            pid_entry = entry;
        }
        try environment.append(a, null);
        return .{
            .argv = argv,
            .candidates = candidates.items,
            .envp = @ptrCast(environment.items.ptr),
            .cwd = if (options.directory) |value| try a.dupeSentinel(u8, value, 0) else null,
            .options = options,
            .pid_entry = pid_entry,
        };
    }

    /// Runs in the child: set up descriptors and exec, or report errno and exit.
    fn run(self: *const Exec, report: linux.fd_t, stderr_pipe: linux.fd_t) noreturn {
        var empty: linux.sigset_t = linux.sigemptyset();
        _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
        var failure: linux.E = .NOENT;
        if (self.options.silence_stdout) {
            const opened = linux.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0);
            if (linux.errno(opened) == .SUCCESS) _ = linux.dup2(@intCast(opened), 1);
        }
        if (stderr_pipe >= 0) _ = linux.dup2(stderr_pipe, 2);
        if (self.pid_entry) |entry| {
            // Formatted without allocating: the child may only make system calls.
            var digits: [20]u8 = undefined;
            var value: usize = @intCast(linux.getpid());
            var start: usize = digits.len;
            while (true) {
                start -= 1;
                digits[start] = @intCast('0' + value % 10);
                value /= 10;
                if (value == 0) break;
            }
            const offset = std.mem.indexOfScalar(u8, entry, '=').? + 1;
            @memcpy(entry[offset..][0 .. digits.len - start], digits[start..]);
            entry[offset + digits.len - start] = 0;
        }
        // Only the requested descriptors survive exec, plus the report pipe until it succeeds.
        _ = linux.close_range(3, std.math.maxInt(linux.fd_t), .{ .CLOEXEC = true, .UNSHARE = false });
        for (self.options.fds) |mapping| {
            if (mapping.source == mapping.target) {
                _ = linux.fcntl(mapping.target, linux.F.SETFD, 0);
            } else _ = linux.dup2(mapping.source, mapping.target);
        }
        if (self.cwd) |path| {
            const changed = linux.errno(linux.chdir(path));
            if (changed != .SUCCESS) fail(report, changed);
        }
        for (self.candidates) |candidate| {
            const result = linux.errno(linux.execve(candidate, self.argv, self.envp));
            // Like execvp, permission errors are remembered while the search continues.
            if (result == .ACCES or failure == .NOENT) failure = result;
        }
        fail(report, failure);
    }

    fn fail(report: linux.fd_t, failure: linux.E) noreturn {
        _ = linux.write(report, std.mem.asBytes(&failure), @sizeOf(linux.E));
        linux.exit_group(127);
    }
};

/// Reads the child's exec report: end of file means exec succeeded.
fn awaitExec(report: linux.fd_t) SpawnError!void {
    var failure: linux.E = .SUCCESS;
    while (true) {
        const got = linux.read(report, std.mem.asBytes(&failure), @sizeOf(linux.E));
        switch (linux.errno(got)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.SpawnFailed,
        }
        if (got == 0) return;
        return switch (failure) {
            .NOENT, .NOTDIR => error.FileNotFound,
            .ACCES, .PERM => error.AccessDenied,
            else => error.SpawnFailed,
        };
    }
}

/// Runs `args` detached from this process, as g_spawn_async does without
/// G_SPAWN_DO_NOT_REAP_CHILD: an intermediate child forks the program and
/// exits, so the program is reparented and needs no reaping. Fails when the
/// program cannot be executed. Descriptors other than the standard streams
/// and `options.fds` are not inherited.
pub fn spawnDetached(gpa: std.mem.Allocator, args: []const [:0]const u8, options: Options) SpawnError!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const exec = try Exec.prepare(arena.allocator(), args, options);
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
        exec.run(report[1], -1);
    }
    _ = linux.close(report[1]);
    defer _ = linux.close(report[0]);
    var status: i32 = 0;
    while (linux.errno(linux.wait4(@intCast(forked), &status, 0, null)) == .INTR) {}
    if (status != 0) return error.SpawnFailed;
    try awaitExec(report[0]);
}

/// How a watched child finished.
pub const Result = struct {
    /// The exit code, or null when a signal ended the process.
    code: ?u8,
    signal: ?u32 = null,
    /// Standard error, when captured; at most 64 KiB.
    stderr: []const u8 = "",
    /// The caller stopped watching before the process finished.
    cancelled: bool = false,

    pub fn successful(self: Result) bool {
        return !self.cancelled and self.code == 0;
    }

    /// A description of a failure, as g_subprocess_wait_check reports it.
    pub fn describe(self: Result, buffer: []u8) []const u8 {
        if (self.cancelled) return "Operation was cancelled";
        if (self.code) |code| return std.fmt.bufPrint(buffer, "Child process exited with code {d}", .{code}) catch "Child process failed";
        return std.fmt.bufPrint(buffer, "Child process killed by signal {d}", .{self.signal orelse 0}) catch "Child process failed";
    }
};

pub const Done = *const fn (?*anyopaque, *const Result) void;

/// A child watched on the GLib main loop. `done` runs exactly once, after the
/// process exits and its captured output closes, or soon after `cancel`; the
/// process is reaped and freed afterwards in either case. Processes may be
/// started from any thread, but the returned pointer may only be used on the
/// main loop's thread, and only until `done` runs.
pub const Process = struct {
    allocator: std.mem.Allocator,
    pid: linux.pid_t,
    pidfd: linux.fd_t,
    stderr_fd: linux.fd_t = -1,
    output: std.ArrayList(u8) = .empty,
    status: ?u32 = null,
    delivered: bool = false,
    cancel_idle: c_uint = 0,
    done: Done,
    context: ?*anyopaque,

    pub fn spawn(gpa: std.mem.Allocator, args: []const [:0]const u8, options: Options, done: Done, context: ?*anyopaque) SpawnError!*Process {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const exec = try Exec.prepare(arena.allocator(), args, options);
        var stderr_pipe: [2]linux.fd_t = .{ -1, -1 };
        if (options.capture_stderr and linux.errno(linux.pipe2(&stderr_pipe, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) return error.SpawnFailed;
        errdefer for (stderr_pipe) |fd| if (fd >= 0) {
            _ = linux.close(fd);
        };
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
            exec.run(report[1], stderr_pipe[1]);
        }
        const pid: linux.pid_t = @intCast(forked);
        _ = linux.close(report[1]);
        if (stderr_pipe[1] >= 0) _ = linux.close(stderr_pipe[1]);
        stderr_pipe[1] = -1;
        const started = awaitExec(report[0]);
        _ = linux.close(report[0]);
        started catch |err| {
            var status: i32 = 0;
            while (linux.errno(linux.wait4(pid, &status, 0, null)) == .INTR) {}
            return err;
        };
        const opened = linux.pidfd_open(pid, 0);
        if (linux.errno(opened) != .SUCCESS) return error.SpawnFailed;
        const self = gpa.create(Process) catch |err| {
            _ = linux.close(@intCast(opened));
            return err;
        };
        self.* = .{ .allocator = gpa, .pid = pid, .pidfd = @intCast(opened), .stderr_fd = stderr_pipe[0], .done = done, .context = context };
        stderr_pipe[0] = -1;
        // Spawning may happen on any thread; the main loop may deliver and free
        // the process as soon as the exit watch is attached, so it goes last.
        if (self.stderr_fd >= 0) _ = glib.g_unix_fd_add(self.stderr_fd, glib.IN | glib.HUP | glib.ERR, &readable, self);
        _ = glib.g_unix_fd_add(self.pidfd, glib.IN, &exited, self);
        return self;
    }

    /// Stops watching: `done` soon receives a cancelled result. The process
    /// keeps running and is still reaped when it exits.
    pub fn cancel(self: *Process) void {
        if (self.delivered or self.cancel_idle != 0) return;
        self.cancel_idle = glib.g_idle_add(&cancelled, self);
    }

    fn cancelled(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Process = @ptrCast(@alignCast(data));
        self.cancel_idle = 0;
        self.deliver(.{ .code = null, .cancelled = true });
        self.finishIfDone();
        return 0;
    }

    fn exited(_: c_int, _: c_uint, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Process = @ptrCast(@alignCast(data));
        var status: i32 = 0;
        while (linux.errno(linux.wait4(self.pid, &status, 0, null)) == .INTR) {}
        self.status = @bitCast(status);
        self.settle();
        return 0;
    }

    fn readable(_: c_int, _: c_uint, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Process = @ptrCast(@alignCast(data));
        var buffer: [4096]u8 = undefined;
        while (true) {
            const got = linux.read(self.stderr_fd, &buffer, buffer.len);
            switch (linux.errno(got)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => return 1,
                else => break,
            }
            if (got == 0) break;
            const room = (64 << 10) -| self.output.items.len;
            self.output.appendSlice(self.allocator, buffer[0..@min(got, room)]) catch {};
        }
        _ = linux.close(self.stderr_fd);
        self.stderr_fd = -1;
        self.settle();
        return 0;
    }

    /// Delivers the result once the process has exited and its output closed.
    fn settle(self: *Process) void {
        const status = self.status orelse return;
        if (self.stderr_fd >= 0) return;
        if (!self.delivered) {
            const signaled = status & 0x7f != 0;
            self.deliver(.{
                .code = if (signaled) null else @intCast((status >> 8) & 0xff),
                .signal = if (signaled) status & 0x7f else null,
                .stderr = self.output.items,
            });
        }
        self.finishIfDone();
    }

    fn deliver(self: *Process, result: Result) void {
        self.delivered = true;
        self.done(self.context, &result);
    }

    fn finishIfDone(self: *Process) void {
        if (self.status == null or self.stderr_fd >= 0 or !self.delivered) return;
        if (self.cancel_idle != 0) _ = glib.g_source_remove(self.cancel_idle);
        _ = linux.close(self.pidfd);
        self.output.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const loop = @import("desktop-loop.zig");
const glib = struct {
    const IN = loop.IN;
    const ERR = loop.ERR;
    const HUP = loop.HUP;
    const g_unix_fd_add = loop.watch;
    const g_idle_add = loop.idle;
    fn g_source_remove(id: c_uint) c_int {
        return @intFromBool(loop.remove(id));
    }
    fn g_main_context_iteration(_: ?*anyopaque, may_block: c_int) c_int {
        return @intFromBool(loop.iteration(may_block != 0));
    }
};

test "command lines split and quote like GLib" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const words = try shellParse(a, "env 'a b' \"c \\\"d\\\" \\x\" e\\ f #comment\n g");
    const expected = [_][]const u8{ "env", "a b", "c \"d\" \\x", "e f", "g" };
    try std.testing.expectEqual(expected.len, words.len);
    for (expected, words) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectError(error.InvalidCommand, shellParse(a, "'unterminated"));
    try std.testing.expectError(error.EmptyCommand, shellParse(a, "  # only a comment"));
    var quoted: std.ArrayList(u8) = .empty;
    try shellQuote(a, &quoted, "it's");
    try std.testing.expectEqualStrings("'it'\\''s'", quoted.items);
}

test "detached programs report exec failures" {
    const a = std.testing.allocator;
    try spawnDetached(a, &.{ "true", "argument" }, .{});
    try std.testing.expectError(error.FileNotFound, spawnDetached(a, &.{"/nonexistent/desktop-process-test"}, .{}));
    try std.testing.expectError(error.FileNotFound, spawnDetached(a, &.{"desktop-process-test-missing-program"}, .{}));
    try std.testing.expectError(error.FileNotFound, spawnDetached(a, &.{"true"}, .{ .directory = "/nonexistent/directory" }));
}

test "watched processes report status, standard error, descriptors and cancellation" {
    const a = std.testing.allocator;
    const Outcome = struct {
        result: ?Result = null,
        stderr: [256]u8 = undefined,
        fn done(data: ?*anyopaque, result: *const Result) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            var copy = result.*;
            const len = @min(result.stderr.len, self.stderr.len);
            @memcpy(self.stderr[0..len], result.stderr[0..len]);
            copy.stderr = self.stderr[0..len];
            self.result = copy;
        }
        fn wait(self: *@This()) Result {
            while (self.result == null) _ = glib.g_main_context_iteration(null, 1);
            return self.result.?;
        }
    };
    var failing: Outcome = .{};
    _ = try Process.spawn(a, &.{ "sh", "-c", "echo broken >&2; exit 3" }, .{ .capture_stderr = true, .silence_stdout = true }, &Outcome.done, &failing);
    const failed = failing.wait();
    try std.testing.expectEqual(@as(?u8, 3), failed.code);
    try std.testing.expectEqualStrings("broken\n", failed.stderr);
    try std.testing.expect(!failed.successful());

    var report: [2]linux.fd_t = undefined;
    try std.testing.expect(linux.errno(linux.pipe2(&report, .{ .CLOEXEC = true })) == .SUCCESS);
    var passing: Outcome = .{};
    _ = try Process.spawn(a, &.{ "sh", "-c", "printf ready >&3" }, .{ .fds = &.{.{ .source = report[1], .target = 3 }} }, &Outcome.done, &passing);
    _ = linux.close(report[1]);
    try std.testing.expect(passing.wait().successful());
    var buffer: [16]u8 = undefined;
    const got = linux.read(report[0], &buffer, buffer.len);
    _ = linux.close(report[0]);
    try std.testing.expectEqualStrings("ready", buffer[0..got]);

    var stopped: Outcome = .{};
    const sleeper = try Process.spawn(a, &.{ "sleep", "0.2" }, .{}, &Outcome.done, &stopped);
    sleeper.cancel();
    try std.testing.expect(stopped.wait().cancelled);
    // The cancelled child is still reaped once it exits.
    const deadline = util.monotonicTime() + 2 * std.time.us_per_s;
    while (util.monotonicTime() < deadline) _ = glib.g_main_context_iteration(null, 0);

    try std.testing.expectError(error.FileNotFound, Process.spawn(a, &.{"desktop-process-test-missing-program"}, .{}, &Outcome.done, &stopped));
}
