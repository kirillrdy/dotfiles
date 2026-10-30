const std = @import("std");
const c = @import("desktop").gtk;
fn ready(window: *c.GtkWidget, entry: *c.GtkWidget, confirmation: ?*c.GtkWidget) void {
    c.gtk_entry_set_text(@ptrCast(entry), "wrong-password");
    if (confirmation) |widget| c.gtk_entry_set_text(@ptrCast(widget), "different-password");
    c.gtk_dialog_response(@ptrCast(window), c.GTK_RESPONSE_OK);
    c.gtk_entry_set_text(@ptrCast(entry), "integration-vault-password");
    if (confirmation) |widget| c.gtk_entry_set_text(@ptrCast(widget), "integration-vault-password");
    c.gtk_dialog_response(@ptrCast(window), c.GTK_RESPONSE_OK);
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, args[1], "import")) {
        return @import("desktop").secrets.importAt(try arena.allocator().dupeSentinel(u8, args[2], 0), "integration-vault-password");
    }
    if (args.len != 2) return error.ExpectedDirectory;
    try @import("desktop").secrets.runAtWithOptions(try arena.allocator().dupeSentinel(u8, args[1], 0), .{
        .prompt_ready = if (c.g_getenv("DESKTOP_SECRETS_FIXTURE_PROMPTS") != null) &ready else null,
    });
}
