const std = @import("std");
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (allocator.deinit() == .leak) @panic("portal allocation leak");
    try @import("portal").runWithAllocator(allocator.allocator());
}
