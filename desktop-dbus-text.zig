//! The GVariant text format for D-Bus values, as `g_variant_print` writes and
//! `g_variant_parse` reads it, so editors can show and accept any value type.
//!
//! Printing annotates types the way GLib does with annotations on: where
//! parsing could not otherwise tell the type. Parsing is directed by the
//! expected signature; annotations are optional and must agree with it.
const std = @import("std");
const dbus = @import("dbus");
const Value = dbus.Value;

pub const Error = error{ OutOfMemory, InvalidText };

/// Formats `value`; the result is owned by `allocator`.
pub fn print(allocator: std.mem.Allocator, value: Value) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    write(&out.writer, value, true) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(w: *std.Io.Writer, value: Value, annotate: bool) std.Io.Writer.Error!void {
    switch (value) {
        .boolean => |v| try w.writeAll(if (v) "true" else "false"),
        .byte => |v| try w.print("{s}0x{x:0>2}", .{ if (annotate) "byte " else "", v }),
        .int16 => |v| try w.print("{s}{d}", .{ if (annotate) "int16 " else "", v }),
        .uint16 => |v| try w.print("{s}{d}", .{ if (annotate) "uint16 " else "", v }),
        .int32 => |v| try w.print("{d}", .{v}),
        .uint32 => |v| try w.print("{s}{d}", .{ if (annotate) "uint32 " else "", v }),
        .int64 => |v| try w.print("{s}{d}", .{ if (annotate) "int64 " else "", v }),
        .uint64 => |v| try w.print("{s}{d}", .{ if (annotate) "uint64 " else "", v }),
        .fd => |v| try w.print("{s}{d}", .{ if (annotate) "handle " else "", v }),
        .double => |v| {
            var buffer: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d}", .{v}) catch unreachable;
            try w.writeAll(text);
            // Keep it a double when read back.
            if (std.mem.indexOfAny(u8, text, ".eEn") == null) try w.writeAll(".0");
        },
        .string => |v| try quoted(w, v),
        .object_path => |v| {
            if (annotate) try w.writeAll("objectpath ");
            try quoted(w, v);
        },
        .signature => |v| {
            if (annotate) try w.writeAll("signature ");
            try quoted(w, v);
        },
        .variant => |inner| {
            try w.writeByte('<');
            try write(w, inner.*, true);
            try w.writeByte('>');
        },
        .bytes => |v| {
            if (v.len == 0) return w.writeAll(if (annotate) "@ay []" else "[]");
            try w.writeByte('[');
            for (v, 0..) |byte, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s}0x{x:0>2}", .{ if (i == 0 and annotate) "byte " else "", byte });
            }
            try w.writeByte(']');
        },
        .array => |array| {
            const dictionary = array.element.len > 0 and array.element[0] == '{';
            if (array.items.len == 0) {
                if (annotate) try w.print("@a{s} ", .{array.element});
                return w.writeAll(if (dictionary) "{}" else "[]");
            }
            try w.writeByte(if (dictionary) '{' else '[');
            for (array.items, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                const first = i == 0 and annotate;
                switch (item) {
                    .dict_entry => |entry| {
                        try write(w, entry[0], first);
                        try w.writeAll(": ");
                        try write(w, entry[1], first);
                    },
                    else => try write(w, item, first),
                }
            }
            try w.writeByte(if (dictionary) '}' else ']');
        },
        .structure => |fields| {
            try w.writeByte('(');
            for (fields, 0..) |field, i| {
                if (i > 0) try w.writeAll(", ");
                try write(w, field, annotate);
            }
            if (fields.len == 1) try w.writeByte(',');
            try w.writeByte(')');
        },
        .dict_entry => |entry| {
            try w.writeByte('{');
            try write(w, entry[0], annotate);
            try w.writeAll(", ");
            try write(w, entry[1], annotate);
            try w.writeByte('}');
        },
    }
}

fn quoted(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    // GLib prefers single quotes unless the text contains one and no double quote.
    const quote: u8 = if (std.mem.indexOfScalar(u8, text, '\'') != null and std.mem.indexOfScalar(u8, text, '"') == null) '"' else '\'';
    try w.writeByte(quote);
    for (text) |ch| switch (ch) {
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0x07 => try w.writeAll("\\a"),
        0x08 => try w.writeAll("\\b"),
        0x0b => try w.writeAll("\\v"),
        0x0c => try w.writeAll("\\f"),
        else => {
            if (ch == quote) {
                try w.writeByte('\\');
                try w.writeByte(ch);
            } else if (ch < 0x20 or ch == 0x7f) {
                try w.print("\\u{x:0>4}", .{ch});
            } else try w.writeByte(ch);
        },
    };
    try w.writeByte(quote);
}

/// Parses `text` as a value of type `signature`, allocating from `arena`.
pub fn parse(arena: std.mem.Allocator, signature: []const u8, text: []const u8) Error!Value {
    if (!dbus.isSingleType(signature)) return error.InvalidText;
    var parser: Parser = .{ .arena = arena, .text = text };
    const value = try parser.typed(signature);
    parser.space();
    if (parser.at != text.len) return error.InvalidText;
    return value;
}

const Parser = struct {
    arena: std.mem.Allocator,
    text: []const u8,
    at: usize = 0,
    depth: usize = 0,

    fn space(self: *Parser) void {
        while (self.at < self.text.len and std.ascii.isWhitespace(self.text[self.at])) self.at += 1;
    }
    fn peek(self: *Parser) ?u8 {
        self.space();
        return if (self.at < self.text.len) self.text[self.at] else null;
    }
    fn eat(self: *Parser, ch: u8) bool {
        if (self.peek() != ch) return false;
        self.at += 1;
        return true;
    }
    fn expect(self: *Parser, ch: u8) Error!void {
        if (!self.eat(ch)) return error.InvalidText;
    }
    fn word(self: *Parser) []const u8 {
        self.space();
        const start = self.at;
        while (self.at < self.text.len and (std.ascii.isAlphanumeric(self.text[self.at]) or self.text[self.at] == '_')) self.at += 1;
        return self.text[start..self.at];
    }
    /// Consumes a type keyword or `@signature` prefix and returns the type it names.
    fn annotation(self: *Parser) Error!?[]const u8 {
        if (self.eat('@')) {
            const start = self.at;
            var end = start;
            while (end < self.text.len and !std.ascii.isWhitespace(self.text[end])) end += 1;
            // The signature is the longest single complete type at this point.
            var length = end - start;
            while (length > 0) : (length -= 1) if (dbus.isSingleType(self.text[start .. start + length])) break;
            if (length == 0) return error.InvalidText;
            self.at = start + length;
            return self.text[start .. start + length];
        }
        const save = self.at;
        const keywords = [_]struct { []const u8, []const u8 }{
            .{ "boolean", "b" }, .{ "byte", "y" },     .{ "int16", "n" },  .{ "uint16", "q" },     .{ "int32", "i" },
            .{ "uint32", "u" },  .{ "int64", "x" },    .{ "uint64", "t" }, .{ "double", "d" },     .{ "handle", "h" },
            .{ "string", "s" },  .{ "objectpath", "o" }, .{ "signature", "g" },
        };
        const name = self.word();
        for (keywords) |entry| if (std.mem.eql(u8, entry[0], name)) return entry[1];
        self.at = save;
        return null;
    }

    fn typed(self: *Parser, signature: []const u8) Error!Value {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 64) return error.InvalidText;
        if (try self.annotation()) |named| if (!std.mem.eql(u8, named, signature)) return error.InvalidText;
        return switch (signature[0]) {
            'b' => .{ .boolean = try self.boolean() },
            'y' => .{ .byte = try self.integer(u8) },
            'n' => .{ .int16 = try self.integer(i16) },
            'q' => .{ .uint16 = try self.integer(u16) },
            'i' => .{ .int32 = try self.integer(i32) },
            'u' => .{ .uint32 = try self.integer(u32) },
            'x' => .{ .int64 = try self.integer(i64) },
            't' => .{ .uint64 = try self.integer(u64) },
            'h' => .{ .fd = try self.integer(i32) },
            'd' => .{ .double = try self.float() },
            's' => .{ .string = try self.string() },
            'o' => .{ .object_path = try self.string() },
            'g' => .{ .signature = try self.string() },
            'v' => blk: {
                try self.expect('<');
                const inner = try self.arena.create(Value);
                inner.* = try self.inferred();
                try self.expect('>');
                break :blk .{ .variant = inner };
            },
            'a' => self.array(signature[1..]),
            '(' => blk: {
                try self.expect('(');
                var fields: std.ArrayList(Value) = .empty;
                var at: usize = 1;
                while (signature[at] != ')') {
                    const next = completeType(signature, at);
                    if (fields.items.len > 0) try self.expect(',');
                    try fields.append(self.arena, try self.typed(signature[at..next]));
                    at = next;
                }
                _ = self.eat(',');
                try self.expect(')');
                break :blk .{ .structure = fields.items };
            },
            else => error.InvalidText,
        };
    }
    fn array(self: *Parser, element: []const u8) Error!Value {
        if (std.mem.eql(u8, element, "y")) {
            if (self.peek() == 'b') return .{ .bytes = try self.byteString() };
            try self.expect('[');
            var items: std.ArrayList(u8) = .empty;
            while (!self.eat(']')) {
                if (items.items.len > 0) try self.expect(',');
                if (try self.annotation()) |named| if (!std.mem.eql(u8, named, "y")) return error.InvalidText;
                try items.append(self.arena, try self.integer(u8));
            }
            return .{ .bytes = items.items };
        }
        var items: std.ArrayList(Value) = .empty;
        if (element[0] == '{') {
            const key_end = completeType(element, 1);
            const value_end = completeType(element, key_end);
            try self.expect('{');
            while (!self.eat('}')) {
                if (items.items.len > 0) try self.expect(',');
                const entry = try self.arena.create([2]Value);
                entry[0] = try self.typed(element[1..key_end]);
                try self.expect(':');
                entry[1] = try self.typed(element[key_end..value_end]);
                try items.append(self.arena, .{ .dict_entry = entry });
            }
        } else {
            try self.expect('[');
            while (!self.eat(']')) {
                if (items.items.len > 0) try self.expect(',');
                try items.append(self.arena, try self.typed(element));
            }
        }
        return .{ .array = .{ .element = try self.arena.dupe(u8, element), .items = items.items } };
    }

    /// A value whose type comes from the text alone, as inside `<...>`.
    fn inferred(self: *Parser) Error!Value {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 64) return error.InvalidText;
        if (try self.annotation()) |named| return self.typed(named);
        const ch = self.peek() orelse return error.InvalidText;
        switch (ch) {
            '\'', '"' => return .{ .string = try self.string() },
            '<' => {
                self.at += 1;
                const inner = try self.arena.create(Value);
                inner.* = try self.inferred();
                try self.expect('>');
                return .{ .variant = inner };
            },
            '(' => {
                self.at += 1;
                var fields: std.ArrayList(Value) = .empty;
                while (!self.eat(')')) {
                    if (fields.items.len > 0) {
                        try self.expect(',');
                        if (self.eat(')')) break;
                    }
                    try fields.append(self.arena, try self.inferred());
                }
                if (fields.items.len == 0) return error.InvalidText;
                return .{ .structure = fields.items };
            },
            '[', '{' => {
                // The first element names the element type; the rest must agree.
                const start = self.at;
                self.at += 1;
                if (self.eat(if (ch == '[') ']' else '}')) return error.InvalidText;
                const first = try self.inferred();
                var element_buffer: [256]u8 = undefined;
                var element = first.signatureInto(&element_buffer) catch return error.InvalidText;
                var dictionary_buffer: [256]u8 = undefined;
                if (ch == '{') {
                    try self.expect(':');
                    const value = try self.inferred();
                    var value_buffer: [256]u8 = undefined;
                    const value_signature = value.signatureInto(&value_buffer) catch return error.InvalidText;
                    element = std.fmt.bufPrint(&dictionary_buffer, "{{{s}{s}}}", .{ element, value_signature }) catch return error.InvalidText;
                }
                self.at = start;
                return self.array(try self.arena.dupe(u8, element));
            },
            'b' => if (self.at + 1 < self.text.len and (self.text[self.at + 1] == '\'' or self.text[self.at + 1] == '"')) return .{ .bytes = try self.byteString() },
            else => {},
        }
        if (ch == 't' or ch == 'f') return .{ .boolean = try self.boolean() };
        // Numbers: integers default to int32 and anything with a fraction to double.
        const start = self.at;
        var end = start;
        while (end < self.text.len and (std.ascii.isAlphanumeric(self.text[end]) or self.text[end] == '-' or self.text[end] == '+' or self.text[end] == '.')) end += 1;
        const token = self.text[start..end];
        const hex = std.mem.startsWith(u8, std.mem.trimStart(u8, token, "-+"), "0x");
        if (!hex and std.mem.indexOfAny(u8, token, ".eE") != null or std.mem.eql(u8, token, "inf") or std.mem.eql(u8, token, "nan")) return .{ .double = try self.float() };
        return .{ .int32 = try self.integer(i32) };
    }

    fn boolean(self: *Parser) Error!bool {
        const name = self.word();
        if (std.mem.eql(u8, name, "true")) return true;
        if (std.mem.eql(u8, name, "false")) return false;
        return error.InvalidText;
    }
    fn number(self: *Parser) []const u8 {
        self.space();
        const start = self.at;
        while (self.at < self.text.len and (std.ascii.isAlphanumeric(self.text[self.at]) or self.text[self.at] == '-' or self.text[self.at] == '+' or self.text[self.at] == '.')) self.at += 1;
        return self.text[start..self.at];
    }
    fn integer(self: *Parser, comptime T: type) Error!T {
        const token = self.number();
        const negative = std.mem.startsWith(u8, token, "-");
        const digits = std.mem.trimStart(u8, token, "-+");
        const base: u8 = if (std.mem.startsWith(u8, digits, "0x") or std.mem.startsWith(u8, digits, "0X")) 16 else 10;
        const magnitude = std.fmt.parseInt(u64, if (base == 16) digits[2..] else digits, base) catch return error.InvalidText;
        if (negative) {
            if (@typeInfo(T).int.signedness == .unsigned and magnitude != 0) return error.InvalidText;
            if (@as(u128, magnitude) > @as(u128, std.math.maxInt(T)) + 1) return error.InvalidText;
            return @intCast(-@as(i128, magnitude));
        }
        return std.math.cast(T, magnitude) orelse error.InvalidText;
    }
    fn float(self: *Parser) Error!f64 {
        return std.fmt.parseFloat(f64, self.number()) catch error.InvalidText;
    }
    fn string(self: *Parser) Error![]const u8 {
        const quote = self.peek() orelse return error.InvalidText;
        if (quote != '\'' and quote != '"') return error.InvalidText;
        self.at += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.at >= self.text.len) return error.InvalidText;
            const ch = self.text[self.at];
            self.at += 1;
            if (ch == quote) break;
            if (ch != '\\') {
                try out.append(self.arena, ch);
                continue;
            }
            if (self.at >= self.text.len) return error.InvalidText;
            const escape = self.text[self.at];
            self.at += 1;
            switch (escape) {
                'n' => try out.append(self.arena, '\n'),
                't' => try out.append(self.arena, '\t'),
                'r' => try out.append(self.arena, '\r'),
                'a' => try out.append(self.arena, 0x07),
                'b' => try out.append(self.arena, 0x08),
                'v' => try out.append(self.arena, 0x0b),
                'f' => try out.append(self.arena, 0x0c),
                'u', 'U' => {
                    const width: usize = if (escape == 'u') 4 else 8;
                    if (self.at + width > self.text.len) return error.InvalidText;
                    const code = std.fmt.parseInt(u21, self.text[self.at .. self.at + width], 16) catch return error.InvalidText;
                    self.at += width;
                    var buffer: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(code, &buffer) catch return error.InvalidText;
                    try out.appendSlice(self.arena, buffer[0..length]);
                },
                else => try out.append(self.arena, escape),
            }
        }
        if (!std.unicode.utf8ValidateSlice(out.items)) return error.InvalidText;
        return out.items;
    }
    /// `b'...'`: bytes with C-style escapes, as GLib prints byte strings.
    fn byteString(self: *Parser) Error![]const u8 {
        if (self.peek() != 'b') return error.InvalidText;
        self.at += 1;
        const quote = if (self.at < self.text.len) self.text[self.at] else return error.InvalidText;
        if (quote != '\'' and quote != '"') return error.InvalidText;
        self.at += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.at >= self.text.len) return error.InvalidText;
            const ch = self.text[self.at];
            self.at += 1;
            if (ch == quote) break;
            if (ch != '\\') {
                try out.append(self.arena, ch);
                continue;
            }
            if (self.at >= self.text.len) return error.InvalidText;
            const escape = self.text[self.at];
            self.at += 1;
            switch (escape) {
                'n' => try out.append(self.arena, '\n'),
                't' => try out.append(self.arena, '\t'),
                'r' => try out.append(self.arena, '\r'),
                '0'...'7' => {
                    var code: u16 = escape - '0';
                    var count: usize = 1;
                    while (count < 3 and self.at < self.text.len and self.text[self.at] >= '0' and self.text[self.at] <= '7') : (count += 1) {
                        code = code * 8 + (self.text[self.at] - '0');
                        self.at += 1;
                    }
                    if (code > 255) return error.InvalidText;
                    try out.append(self.arena, @intCast(code));
                },
                else => try out.append(self.arena, escape),
            }
        }
        // GLib's byte strings carry their terminating nul.
        try out.append(self.arena, 0);
        return out.items;
    }
};

fn completeType(code: []const u8, start: usize) usize {
    var at = start;
    var depth: usize = 0;
    while (at < code.len) : (at += 1) {
        switch (code[at]) {
            'a' => continue,
            '(', '{' => depth += 1,
            ')', '}' => depth -= 1,
            else => {},
        }
        if (depth == 0) return at + 1;
    }
    return code.len;
}

test "values print like GLib and parse back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "u", "uint32 42" },
        .{ "i", "-7" },
        .{ "d", "1.5" },
        .{ "s", "\"it's\"" },
        .{ "as", "['a', 'b']" },
        .{ "as", "@as []" },
        .{ "a{sv}", "{'id': <'home'>, 'mtu': <uint32 1500>}" },
        .{ "aa{sv}", "[{'address': <'192.0.2.1'>, 'prefix': <uint32 24>}]" },
        .{ "(ib)", "(1, true)" },
        .{ "(s)", "('x',)" },
        .{ "ay", "[byte 0x41, 0x00]" },
        .{ "o", "objectpath '/org/x'" },
        .{ "v", "<@a{ss} {'k': 'v'}>" },
        .{ "a{sa{sv}}", "{'vpn': {'secrets': <@a{ss} {'password': 'old'}>}}" },
    };
    for (cases) |case| {
        const value = parse(a, case[0], case[1]) catch |err| {
            std.debug.print("failed to parse {s} as {s}\n", .{ case[1], case[0] });
            return err;
        };
        var buffer: [256]u8 = undefined;
        try std.testing.expectEqualStrings(case[0], try value.signatureInto(&buffer));
        const printed = try print(a, value);
        const again = try parse(a, case[0], printed);
        try std.testing.expectEqualStrings(printed, try print(a, again));
    }
    try std.testing.expectEqualStrings("uint32 42", try print(a, try parse(a, "u", "42")));
    try std.testing.expectEqualStrings("'a\\'b\"'", try print(a, .{ .string = "a'b\"" }));
    try std.testing.expectError(error.InvalidText, parse(a, "u", "-1"));
    try std.testing.expectError(error.InvalidText, parse(a, "y", "256"));
    try std.testing.expectError(error.InvalidText, parse(a, "s", "'open"));
    try std.testing.expectError(error.InvalidText, parse(a, "u", "int32 5"));
    try std.testing.expectError(error.InvalidText, parse(a, "as", "[1]"));
    try std.testing.expectEqualSlices(u8, "hi\x00", (try parse(a, "ay", "b'hi'")).bytes);
}
