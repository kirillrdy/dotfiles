const std = @import("std");
fn authenticate(_: [*:0]const u8, password: [*:0]const u8) bool {
    const success = std.mem.eql(u8, std.mem.span(password), "fixture-password");
    std.debug.print("fixture-auth: {s}\n", .{if (success) "accepted" else "rejected"});
    return success;
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    const start: usize = if (args.len > 1 and std.mem.eql(u8, args[1], "lock")) 2 else 1;
    try @import("desktop").lock.runWithAuthenticator(args[start..], authenticate);
}
