//! Run commands from a compositor-like worker while the main loop observes exits.
const std = @import("std");
const desktop = @import("desktop");
const commands = desktop.commands;
const c = desktop.screenshot.c;
const libc = desktop.libc;

fn work(allocator: std.mem.Allocator, binary: [:0]const u8) void {
    commands.launch(allocator, "Successful command", &.{ binary, "success" });
    commands.launch(allocator, "Nonzero command", &.{ binary, "failure" });
    commands.launch(allocator, "Signaled command", &.{ binary, "signal" });
    commands.commandLine(allocator, "Missing command", "/nonexistent/desktop-command-fixture");
    commands.commandLine(allocator, "Invalid command", "'");
}

fn stop(data: c.gpointer) callconv(.c) c.gboolean {
    const done: *bool = @ptrCast(@alignCast(data.?));
    done.* = true;
    return 0;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "failure")) std.process.exit(7);
        if (std.mem.eql(u8, args[1], "signal")) {
            _ = libc.raise(libc.SIGTERM);
            unreachable;
        }
        return;
    }
    const thread = try std.Thread.spawn(.{}, work, .{ init.gpa, args[0] });
    thread.join();
    var done = false;
    _ = c.g_timeout_add(1500, &stop, &done);
    while (!done) _ = c.g_main_context_iteration(null, 1);
}
