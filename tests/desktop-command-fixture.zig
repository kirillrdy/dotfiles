//! Run commands from a compositor-like worker while the main loop observes exits.
const std = @import("std");
const desktop = @import("desktop");
const commands = desktop.commands;
const c = desktop.screenshot.c;
const libc = desktop.libc;

fn work(binary: [:0]const u8) void {
    const success = [_:null]?[*:0]const u8{ binary, "success" };
    commands.launch("Successful command", @ptrCast(&success));
    const failure = [_:null]?[*:0]const u8{ binary, "failure" };
    commands.launch("Nonzero command", @ptrCast(&failure));
    const signal = [_:null]?[*:0]const u8{ binary, "signal" };
    commands.launch("Signaled command", @ptrCast(&signal));
    commands.commandLine("Missing command", "/nonexistent/desktop-command-fixture");
    commands.commandLine("Invalid command", "'");
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
    const thread = try std.Thread.spawn(.{}, work, .{args[0]});
    thread.join();
    var done = false;
    _ = c.g_timeout_add(1500, &stop, &done);
    while (!done) _ = c.g_main_context_iteration(null, 1);
}
