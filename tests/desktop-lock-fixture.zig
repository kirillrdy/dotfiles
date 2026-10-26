const std = @import("std");
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    const start: usize = if (args.len > 1 and std.mem.eql(u8, args[1], "lock")) 2 else 1;
    try @import("lock").run(args[start..]);
}
