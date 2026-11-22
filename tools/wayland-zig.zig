//! Generate typed Zig Wayland client bindings for desktop-wire.zig from protocol XML.
//!
//! Each interface becomes a struct holding a `wire.Proxy` with one method per
//! request, an `Event` union in opcode order and `listen` for typed handlers.
const std = @import("std");

const Arg = struct {
    name: []const u8,
    kind: []const u8,
    interface: ?[]const u8 = null,
    allow_null: bool = false,
};

const Message = struct {
    name: []const u8,
    since: []const u8 = "1",
    destructor: bool = false,
    args: []const Arg = &.{},
};

const EnumEntry = struct {
    name: []const u8,
    value: []const u8,
};

const Enum = struct {
    name: []const u8,
    entries: []const EnumEntry = &.{},
};

const Interface = struct {
    name: []const u8,
    version: []const u8,
    requests: []const Message = &.{},
    events: []const Message = &.{},
    enums: []const Enum = &.{},
};

const keywords = [_][]const u8{
    "error",     "type",          "fn",            "const",         "var",            "return",    "align",
    "and",       "or",            "struct",        "enum",          "union",          "test",      "export",
    "extern",    "async",         "await",         "resume",        "suspend",        "break",     "continue",
    "defer",     "if",            "else",          "for",           "while",          "switch",    "true",
    "false",     "null",          "undefined",     "pub",           "try",            "catch",     "orelse",
    "inline",    "comptime",      "opaque",        "packed",        "noalias",        "anytype",   "anyframe",
    "callconv",  "linksection",   "threadlocal",   "usingnamespace", "volatile",      "allowzero", "asm",
    "errdefer",  "unreachable",   "nosuspend",
};

fn isKeyword(name: []const u8) bool {
    for (keywords) |kw| if (std.mem.eql(u8, name, kw)) return true;
    return false;
}

fn ident(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len == 0 or isKeyword(name) or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) {
        return std.fmt.allocPrint(a, "@\"{s}\"", .{name});
    }
    return name;
}

fn camel(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var parts = std.mem.splitScalar(u8, name, '_');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        try out.append(a, std.ascii.toUpper(part[0]));
        try out.appendSlice(a, part[1..]);
    }
    return out.toOwnedSlice(a);
}

fn kindChar(kind: []const u8) !u8 {
    if (std.mem.eql(u8, kind, "int")) return 'i';
    if (std.mem.eql(u8, kind, "uint")) return 'u';
    if (std.mem.eql(u8, kind, "fixed")) return 'f';
    if (std.mem.eql(u8, kind, "string")) return 's';
    if (std.mem.eql(u8, kind, "object")) return 'o';
    if (std.mem.eql(u8, kind, "new_id")) return 'n';
    if (std.mem.eql(u8, kind, "array")) return 'a';
    if (std.mem.eql(u8, kind, "fd")) return 'h';
    return error.UnknownArgType;
}

fn signature(a: std.mem.Allocator, message: Message) ![]const u8 {
    var sig: std.ArrayList(u8) = .empty;
    for (message.args) |arg| {
        if (std.mem.eql(u8, arg.kind, "new_id") and arg.interface == null) {
            try sig.appendSlice(a, "sun");
            continue;
        }
        if (arg.allow_null) try sig.append(a, '?');
        try sig.append(a, try kindChar(arg.kind));
    }
    return sig.toOwnedSlice(a);
}

fn eventType(a: std.mem.Allocator, arg: Arg, known: *const std.StringHashMapUnmanaged(void)) ![]const u8 {
    if (std.mem.eql(u8, arg.kind, "int")) return "i32";
    if (std.mem.eql(u8, arg.kind, "uint")) return "u32";
    if (std.mem.eql(u8, arg.kind, "fixed")) return "f64";
    if (std.mem.eql(u8, arg.kind, "string")) return if (arg.allow_null) "?[:0]const u8" else "[:0]const u8";
    if (std.mem.eql(u8, arg.kind, "array")) return "[]const u8";
    if (std.mem.eql(u8, arg.kind, "fd")) return "wire.Fd";
    if (std.mem.eql(u8, arg.kind, "object") or std.mem.eql(u8, arg.kind, "new_id")) {
        const base = if (arg.interface) |target| (if (known.contains(target)) target else "wire.Proxy") else "wire.Proxy";
        return if (arg.allow_null) std.fmt.allocPrint(a, "?{s}", .{base}) else base;
    }
    return error.UnknownArgType;
}

fn requestType(a: std.mem.Allocator, arg: Arg, known: *const std.StringHashMapUnmanaged(void)) ![]const u8 {
    if (std.mem.eql(u8, arg.kind, "string")) return if (arg.allow_null) "?[:0]const u8" else "[:0]const u8";
    if (std.mem.eql(u8, arg.kind, "array")) return "[]const u8";
    if (std.mem.eql(u8, arg.kind, "fd")) return "i32";
    return eventType(a, arg, known);
}

fn formatMessages(a: std.mem.Allocator, list: []const Message, known: *const std.StringHashMapUnmanaged(void)) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (list, 0..) |message, idx| {
        if (idx > 0) try out.appendSlice(a, ", ");
        var new_id: ?[]const u8 = null;
        for (message.args) |arg| {
            if (std.mem.eql(u8, arg.kind, "new_id")) {
                if (arg.interface) |target| if (known.contains(target)) {
                    new_id = target;
                };
            }
        }
        try out.print(a, ".{{ .name = \"{s}\", .signature = \"{s}\", .since = {s}, .destructor = {s}", .{
            message.name,
            try signature(a, message),
            message.since,
            if (message.destructor) "true" else "false",
        });
        if (new_id) |target| {
            try out.print(a, ", .new_id = struct {{ fn get() *const wire.Interface {{ return &{s}.interface; }} }}.get", .{target});
        }
        try out.appendSlice(a, " }");
    }
    return out.toOwnedSlice(a);
}

fn attribute(attributes: []const u8, key: []const u8) ?[]const u8 {
    var rest = attributes;
    while (true) {
        rest = std.mem.trimStart(u8, rest, " \t\r\n");
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
        const name = std.mem.trim(u8, rest[0..eq], " \t\r\n");
        const after = std.mem.trimStart(u8, rest[eq + 1 ..], " \t\r\n");
        if (after.len == 0 or (after[0] != '"' and after[0] != '\'')) return null;
        const quote = after[0];
        const close = std.mem.indexOfScalarPos(u8, after, 1, quote) orelse return null;
        if (std.mem.eql(u8, name, key)) return after[1..close];
        rest = after[close + 1 ..];
    }
}

fn parseXml(a: std.mem.Allocator, xml: []const u8, interfaces: *std.ArrayList(Interface)) !void {
    var current_iface: ?Interface = null;
    var requests: std.ArrayList(Message) = .empty;
    var events: std.ArrayList(Message) = .empty;
    var enums: std.ArrayList(Enum) = .empty;
    var current_msg: ?Message = null;
    var current_msg_is_event = false;
    var args: std.ArrayList(Arg) = .empty;
    var current_enum: ?Enum = null;
    var entries: std.ArrayList(EnumEntry) = .empty;

    var position: usize = 0;
    while (std.mem.indexOfScalarPos(u8, xml, position, '<')) |start| {
        if (std.mem.startsWith(u8, xml[start..], "<!--")) {
            position = (std.mem.indexOfPos(u8, xml, start, "-->") orelse return error.InvalidXml) + 3;
            continue;
        }
        if (std.mem.startsWith(u8, xml[start..], "<![CDATA[")) {
            position = (std.mem.indexOfPos(u8, xml, start, "]]>") orelse return error.InvalidXml) + 3;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, xml, start, '>') orelse return error.InvalidXml;
        position = end + 1;
        if (xml[start + 1] == '?' or xml[start + 1] == '!') continue;
        const closing = xml[start + 1] == '/';
        var tag = std.mem.trim(u8, xml[start + 1 + @intFromBool(closing) .. end], " \t\r\n");
        const self_closing = tag.len > 0 and tag[tag.len - 1] == '/';
        if (self_closing) tag = std.mem.trimEnd(u8, tag[0 .. tag.len - 1], " \t\r\n");
        const name_end = std.mem.indexOfAny(u8, tag, " \t\r\n") orelse tag.len;
        const element = tag[0..name_end];
        const attrs = tag[name_end..];

        if (std.mem.eql(u8, element, "interface")) {
            if (closing) {
                var iface = current_iface orelse return error.InvalidXml;
                iface.requests = try requests.toOwnedSlice(a);
                iface.events = try events.toOwnedSlice(a);
                iface.enums = try enums.toOwnedSlice(a);
                try interfaces.append(a, iface);
                current_iface = null;
            } else if (!self_closing) {
                current_iface = .{
                    .name = attribute(attrs, "name") orelse return error.InvalidXml,
                    .version = attribute(attrs, "version") orelse return error.InvalidXml,
                };
            }
        } else if (current_iface != null and (std.mem.eql(u8, element, "request") or std.mem.eql(u8, element, "event"))) {
            if (!closing) {
                current_msg_is_event = std.mem.eql(u8, element, "event");
                current_msg = .{
                    .name = attribute(attrs, "name") orelse return error.InvalidXml,
                    .since = attribute(attrs, "since") orelse "1",
                    .destructor = if (attribute(attrs, "type")) |t| std.mem.eql(u8, t, "destructor") else false,
                };
                args.clearRetainingCapacity();
            }
            if (closing or self_closing) {
                var msg = current_msg orelse return error.InvalidXml;
                msg.args = try args.toOwnedSlice(a);
                if (current_msg_is_event) try events.append(a, msg) else try requests.append(a, msg);
                current_msg = null;
            }
        } else if (current_msg != null and std.mem.eql(u8, element, "arg") and !closing) {
            try args.append(a, .{
                .name = attribute(attrs, "name") orelse return error.InvalidXml,
                .kind = attribute(attrs, "type") orelse return error.InvalidXml,
                .interface = attribute(attrs, "interface"),
                .allow_null = if (attribute(attrs, "allow-null")) |v| std.mem.eql(u8, v, "true") else false,
            });
        } else if (current_iface != null and std.mem.eql(u8, element, "enum")) {
            if (!closing) {
                current_enum = .{ .name = attribute(attrs, "name") orelse return error.InvalidXml };
                entries.clearRetainingCapacity();
            }
            if (closing or self_closing) {
                var e = current_enum orelse return error.InvalidXml;
                e.entries = try entries.toOwnedSlice(a);
                try enums.append(a, e);
                current_enum = null;
            }
        } else if (current_enum != null and std.mem.eql(u8, element, "entry") and !closing) {
            try entries.append(a, .{
                .name = attribute(attrs, "name") orelse return error.InvalidXml,
                .value = attribute(attrs, "value") orelse return error.InvalidXml,
            });
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 3) return error.Usage;
    const cwd = std.Io.Dir.cwd();
    var interfaces: std.ArrayList(Interface) = .empty;
    for (args[2..]) |path| {
        const xml = try cwd.readFileAlloc(io, path, a, .limited(16 << 20));
        try parseXml(a, xml, &interfaces);
    }
    var known: std.StringHashMapUnmanaged(void) = .empty;
    for (interfaces.items) |iface| try known.put(a, iface.name, {});

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "// Generated from protocol XML by tools/wayland-zig.zig. Do not edit.\n");
    try out.appendSlice(a, "const wire = @import(\"wayland-wire\");\n");
    for (interfaces.items) |iface| {
        try out.print(a, "pub const {s} = struct {{\n", .{iface.name});
        try out.appendSlice(a, "    proxy: wire.Proxy,\n");
        try out.appendSlice(a, "    const Self = @This();\n");
        try out.print(a, "    pub const interface: wire.Interface = .{{ .name = \"{s}\", .version = {s}, .requests = &.{{ {s} }}, .events = &.{{ {s} }} }};\n", .{
            iface.name,
            iface.version,
            try formatMessages(a, iface.requests, &known),
            try formatMessages(a, iface.events, &known),
        });
        try out.appendSlice(a, "    pub const Event = union(enum) {\n");
        for (iface.events) |event| {
            try out.print(a, "        {s}: struct {{ ", .{try ident(a, event.name)});
            for (event.args, 0..) |arg, idx| {
                if (idx > 0) try out.appendSlice(a, ", ");
                try out.print(a, "{s}: {s}", .{ try ident(a, arg.name), try eventType(a, arg, &known) });
            }
            try out.appendSlice(a, " },\n");
        }
        try out.appendSlice(a, "    };\n");
        // Parameters must not shadow the struct's own declarations.
        var taken: std.StringHashMapUnmanaged(void) = .empty;
        for ([_][]const u8{ "Self", "Event", "interface", "listen", "version", "destroy", "proxy", "wire" }) |reserved| {
            try taken.put(a, reserved, {});
        }
        for (iface.requests) |req| try taken.put(a, req.name, {});
        for (iface.enums) |e| try taken.put(a, try camel(a, e.name), {});

        for (iface.enums) |e| {
            try out.print(a, "    pub const {s} = struct {{\n", .{try camel(a, e.name)});
            for (e.entries) |entry| {
                try out.print(a, "        pub const {s}: u32 = {s};\n", .{ try ident(a, entry.name), entry.value });
            }
            try out.appendSlice(a, "    };\n");
        }
        try out.appendSlice(a, "    pub fn listen(self: Self, comptime Data: type, data: *Data, comptime handler: fn (*Data, Self, Event) void) void {\n");
        try out.appendSlice(a, "        self.proxy.listen(Self, Data, data, handler);\n");
        try out.appendSlice(a, "    }\n");
        try out.appendSlice(a, "    pub fn version(self: Self) u32 {\n");
        try out.appendSlice(a, "        return self.proxy.version();\n");
        try out.appendSlice(a, "    }\n");
        var has_destroy = false;
        for (iface.requests, 0..) |req, opcode| {
            if (std.mem.eql(u8, req.name, "destroy")) has_destroy = true;
            var params: std.ArrayList(u8) = .empty;
            try params.appendSlice(a, "self: Self");
            var values: std.ArrayList(u8) = .empty;
            var returns: []const u8 = "void";
            var new_interface: []const u8 = "null";
            var untyped = false;
            for (req.args) |arg| {
                const raw = if (taken.contains(arg.name)) try std.fmt.allocPrint(a, "{s}_value", .{arg.name}) else arg.name;
                const aname = try ident(a, raw);
                if (std.mem.eql(u8, arg.kind, "new_id")) {
                    if (arg.interface) |target| {
                        if (values.items.len > 0) try values.appendSlice(a, ", ");
                        try values.appendSlice(a, "wire.new_id");
                        returns = if (known.contains(target)) target else "wire.Proxy";
                        new_interface = if (known.contains(target)) try std.fmt.allocPrint(a, "&{s}.interface", .{target}) else "null";
                    } else {
                        untyped = true;
                        try params.appendSlice(a, ", comptime T: type, bind_version: u32");
                        if (values.items.len > 0) try values.appendSlice(a, ", ");
                        try values.appendSlice(a, "T.interface.name, bind_version, wire.new_id");
                        returns = "T";
                        new_interface = "&T.interface";
                    }
                    continue;
                }
                try params.print(a, ", {s}: {s}", .{ aname, try requestType(a, arg, &known) });
                if (values.items.len > 0) try values.appendSlice(a, ", ");
                try values.appendSlice(a, aname);
            }
            const ver = if (untyped) "bind_version" else "null";
            const call = try std.fmt.allocPrint(a, "self.proxy.send({d}, interface.requests[{d}], {s}, {s}, .{{ {s} }})", .{
                opcode,
                opcode,
                new_interface,
                ver,
                values.items,
            });
            try out.print(a, "    pub fn {s}({s}) {s} {{\n", .{ try ident(a, req.name), params.items, returns });
            if (std.mem.eql(u8, returns, "void")) {
                try out.print(a, "        _ = {s};\n", .{call});
            } else if (std.mem.eql(u8, returns, "wire.Proxy")) {
                try out.print(a, "        return {s};\n", .{call});
            } else {
                try out.print(a, "        return .{{ .proxy = {s} }};\n", .{call});
            }
            try out.appendSlice(a, "    }\n");
        }
        if (!has_destroy) {
            try out.appendSlice(a, "    /// Forgets the object locally; the protocol has no destructor request.\n");
            try out.appendSlice(a, "    pub fn destroy(self: Self) void {\n");
            try out.appendSlice(a, "        self.proxy.forget();\n");
            try out.appendSlice(a, "    }\n");
        }
        try out.appendSlice(a, "};\n");
    }
    try cwd.writeFile(io, .{ .sub_path = args[1], .data = out.items });
}
