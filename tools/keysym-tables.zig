//! Generate keysym name and Unicode tables for desktop-xkb.zig from
//! xkbcommon-keysyms.h: the names xkbcommon accepts and writes in keymaps.
//! It is read as data; nothing from xkbcommon is linked.
//! Usage: keysym-tables OUTPUT xkbcommon-keysyms.h
const std = @import("std");

const Name = struct { name: []const u8, keysym: u32 };
const Pair = struct { keysym: u32, cp: u32, deprecated: bool };

fn lessName(_: void, x: Name, y: Name) bool {
    return std.mem.lessThan(u8, x.name, y.name);
}
fn lessPair(_: void, x: Pair, y: Pair) bool {
    return x.keysym < y.keysym;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.Usage;
    const cwd = std.Io.Dir.cwd();
    var names: std.ArrayList(Name) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var unicode: std.ArrayList(Pair) = .empty;
    var mapped: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const text = try cwd.readFileAlloc(io, args[2], a, .limited(4 << 20));
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "#define")) continue;
        var fields = std.mem.tokenizeAny(u8, line["#define".len..], " \t");
        const macro = fields.next() orelse continue;
        const value = fields.next() orelse continue;
        if (!std.mem.startsWith(u8, macro, "XKB_KEY_") or !std.mem.startsWith(u8, value, "0x")) continue;
        const keysym = std.fmt.parseInt(u32, value[2..], 16) catch continue;
        const name = macro["XKB_KEY_".len..];
        if (!(try seen.getOrPut(a, name)).found_existing) try names.append(a, .{ .name = name, .keysym = keysym });
        // Legacy keysyms carry their character as "U+XXXX" (or "(U+XXXX)" when deprecated).
        const marker = std.mem.indexOf(u8, line, "U+") orelse continue;
        var end = marker + 2;
        while (end < line.len and std.ascii.isHex(line[end])) end += 1;
        var cp = std.fmt.parseInt(u32, line[marker + 2 .. end], 16) catch continue;
        // xkbcommon maps the angle brackets to the mathematical ones, not the deprecated U+2329/U+232A.
        if (keysym == 0xabc) cp = 0x27e8;
        if (keysym == 0xabe) cp = 0x27e9;
        // Latin-1 and Unicode keysyms convert arithmetically; others need the table.
        if ((keysym >= 0x20 and keysym <= 0x7e) or (keysym >= 0xa0 and keysym <= 0xff) or keysym >= 0x01000000) continue;
        const deprecated = marker > 0 and line[marker - 1] == '(';
        if (!(try mapped.getOrPut(a, keysym)).found_existing) try unicode.append(a, .{ .keysym = keysym, .cp = cp, .deprecated = deprecated });
    }
    std.mem.sort(Name, names.items, {}, lessName);
    std.mem.sort(Pair, unicode.items, {}, lessPair);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "// Generated from xkbcommon-keysyms.h by tools/keysym-tables.zig. Do not edit.\n");
    try out.appendSlice(a, "pub const Name = struct { name: []const u8, keysym: u32 };\n");
    try out.appendSlice(a, "pub const Pair = struct { keysym: u32, cp: u21, deprecated: bool = false };\n");
    try out.appendSlice(a, "/// Sorted by name.\npub const names = [_]Name{\n");
    for (names.items) |entry| try out.print(a, "    .{{ .name = \"{s}\", .keysym = 0x{x} }},\n", .{ entry.name, entry.keysym });
    try out.appendSlice(a, "};\n/// Legacy keysyms and their characters, sorted by keysym.\npub const unicode = [_]Pair{\n");
    for (unicode.items) |entry| try out.print(a, "    .{{ .keysym = 0x{x}, .cp = 0x{x}{s} }},\n", .{ entry.keysym, entry.cp, if (entry.deprecated) ", .deprecated = true" else "" });
    try out.appendSlice(a, "};\n");
    try cwd.writeFile(io, .{ .sub_path = args[1], .data = out.items });
}
