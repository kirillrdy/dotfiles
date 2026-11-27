//! XKB keymaps, keyboard state and Compose sequences without xkbcommon.
//!
//! Wayland compositors send keymaps in xkbcommon's compiled text format: every
//! section is complete, with no includes. This reads that format and follows
//! xkbcommon's rules for what it leaves implicit: automatic key types, virtual
//! modifier mapping through interpret statements, and key repeat. Modifier
//! state comes from the compositor, so key actions are not interpreted.
const std = @import("std");
const tables = @import("keysym-tables");
const unicode = @import("desktop-unicode.zig");

pub const NoSymbol: u32 = 0;
const max_mods = 32;
const real_mods = [_][]const u8{ "Shift", "Lock", "Control", "Mod1", "Mod2", "Mod3", "Mod4", "Mod5" };
pub const lock_mask: u32 = 1 << 1;

// ---------------------------------------------------------------- Keysyms

/// A keysym by name, as xkbcommon accepts it: a known name, "0x…" or "U…".
pub fn keysymFromName(name: []const u8) ?u32 {
    var low: usize = 0;
    var high: usize = tables.names.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, tables.names[mid].name, name)) {
            .eq => return tables.names[mid].keysym,
            .lt => low = mid + 1,
            .gt => high = mid,
        }
    }
    if (name.len > 2 and name[0] == '0' and (name[1] == 'x' or name[1] == 'X')) return std.fmt.parseInt(u32, name[2..], 16) catch null;
    if (name.len > 1 and name[0] == 'U') {
        const cp = std.fmt.parseInt(u32, name[1..], 16) catch return null;
        if (cp > 0x10ffff) return null;
        return if ((cp >= 0x20 and cp <= 0x7e) or (cp >= 0xa0 and cp <= 0xff)) cp else 0x01000000 + cp;
    }
    return null;
}

/// The character a keysym produces, or 0 (xkb_keysym_to_utf32).
pub fn toUnicode(keysym: u32) u21 {
    if ((keysym >= 0x20 and keysym <= 0x7e) or (keysym >= 0xa0 and keysym <= 0xff)) return @intCast(keysym);
    if (keysym == 0xff80) return ' '; // KP_Space
    // BackSpace..Clear, KP_Multiply..KP_9, Return, Escape, Delete, KP_Tab, KP_Enter, KP_Equal.
    if ((keysym >= 0xff08 and keysym <= 0xff0b) or (keysym >= 0xffaa and keysym <= 0xffb9) or keysym == 0xff0d or keysym == 0xff1b or keysym == 0xffff or keysym == 0xff89 or keysym == 0xff8d or keysym == 0xffbd) return @intCast(keysym & 0x7f);
    if (keysym >= 0x0100d800 and keysym <= 0x0100dfff) return 0;
    if (keysym >= 0x01000000 and keysym <= 0x0110ffff) return @intCast(keysym - 0x01000000);
    if (keysym >= 0x10081200 and keysym <= 0x10081209) return @intCast(keysym - 0x10081200 + '0'); // XF86Numeric0..9
    if (keysym == 0x1008120a) return '*'; // XF86NumericStar
    if (keysym == 0x1008120b) return '#'; // XF86NumericPound
    var low: usize = 0;
    var high: usize = tables.unicode.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (tables.unicode[mid].keysym == keysym) return tables.unicode[mid].cp;
        if (tables.unicode[mid].keysym < keysym) low = mid + 1 else high = mid;
    }
    return 0;
}

/// The keysym for a character, preferring a current legacy keysym (xkb_utf32_to_keysym).
fn fromUnicode(cp: u21) u32 {
    if ((cp >= 0x20 and cp <= 0x7e) or (cp >= 0xa0 and cp <= 0xff)) return cp;
    for (tables.unicode) |entry| if (entry.cp == cp and !entry.deprecated) return entry.keysym;
    return 0x01000000 + @as(u32, cp);
}
fn isLower(keysym: u32) bool {
    const cp = toUnicode(keysym);
    return cp != 0 and unicode.toUpper(cp) != cp;
}
fn isUpper(keysym: u32) bool {
    const cp = toUnicode(keysym);
    return cp != 0 and unicode.toLower(cp) != cp;
}
fn isKeypad(keysym: u32) bool {
    return keysym >= 0xff80 and keysym <= 0xffbd;
}
/// The Caps Lock transformation: the uppercase keysym, when there is one.
fn toUpperKeysym(keysym: u32) u32 {
    const cp = toUnicode(keysym);
    if (cp == 0) return keysym;
    // xkbcommon uppercases ß to ẞ, which Unicode's simple mappings leave alone.
    if (cp == 0xdf) return 0x1001e9e;
    const upper = unicode.toUpper(cp);
    return if (upper == cp) keysym else fromUnicode(upper);
}
/// Keysyms Compose ignores: modifier and lock keys.
fn isModifier(keysym: u32) bool {
    return (keysym >= 0xffe1 and keysym <= 0xffee) or (keysym >= 0xfe01 and keysym <= 0xfe13) or keysym == 0xff7e or keysym == 0xff7f;
}

// ---------------------------------------------------------------- Tokens

const Kind = enum { ident, number, string, keyname, punct };
const Token = struct { kind: Kind, text: []const u8 };

fn tokenize(a: std.mem.Allocator, source: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        if (std.ascii.isWhitespace(c) or c == 0) {
            i += 1;
        } else if (c == '#' or (c == '/' and i + 1 < source.len and source[i + 1] == '/')) {
            while (i < source.len and source[i] != '\n') i += 1;
        } else if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            i = (std.mem.indexOfPos(u8, source, i + 2, "*/") orelse return error.InvalidKeymap) + 2;
        } else if (c == '"') {
            var end = i + 1;
            while (end < source.len and source[end] != '"') : (end += 1) {
                if (source[end] == '\\') end += 1;
            }
            if (end >= source.len) return error.InvalidKeymap;
            try tokens.append(a, .{ .kind = .string, .text = source[i + 1 .. end] });
            i = end + 1;
        } else if (c == '<') {
            const end = std.mem.indexOfScalarPos(u8, source, i, '>') orelse return error.InvalidKeymap;
            try tokens.append(a, .{ .kind = .keyname, .text = source[i + 1 .. end] });
            i = end + 1;
        } else if (std.ascii.isAlphanumeric(c) or c == '_') {
            const start = i;
            while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) i += 1;
            try tokens.append(a, .{ .kind = if (std.ascii.isDigit(c)) .number else .ident, .text = source[start..i] });
        } else {
            try tokens.append(a, .{ .kind = .punct, .text = source[i .. i + 1] });
            i += 1;
        }
    }
    return tokens.toOwnedSlice(a);
}

fn isPunct(token: Token, char: u8) bool {
    return token.kind == .punct and token.text[0] == char;
}

/// Splits tokens at `separator` outside brackets.
const Splitter = struct {
    tokens: []const Token,
    separator: u8,
    fn next(self: *Splitter) ?[]const Token {
        if (self.tokens.len == 0) return null;
        var depth: usize = 0;
        for (self.tokens, 0..) |token, i| {
            if (token.kind != .punct) continue;
            switch (token.text[0]) {
                '{', '[', '(' => depth += 1,
                '}', ']', ')' => depth -|= 1,
                else => if (depth == 0 and token.text[0] == self.separator) {
                    const part = self.tokens[0..i];
                    self.tokens = self.tokens[i + 1 ..];
                    return part;
                },
            }
        }
        const part = self.tokens;
        self.tokens = &.{};
        return part;
    }
};

/// The tokens between the brace starting at `tokens[open]` and its match.
fn braced(tokens: []const Token, open: usize) ![]const Token {
    if (open >= tokens.len or tokens[open].kind != .punct or std.mem.indexOfScalar(u8, "{[(", tokens[open].text[0]) == null) return error.InvalidKeymap;
    var depth: usize = 0;
    for (tokens[open..], open..) |token, i| {
        if (token.kind != .punct) continue;
        switch (token.text[0]) {
            '{', '[', '(' => depth += 1,
            '}', ']', ')' => {
                if (depth == 0) return error.InvalidKeymap;
                depth -= 1;
                if (depth == 0) return tokens[open + 1 .. i];
            },
            else => {},
        }
    }
    return error.InvalidKeymap;
}

fn indexOfPunct(tokens: []const Token, char: u8) ?usize {
    for (tokens, 0..) |token, i| if (isPunct(token, char)) return i;
    return null;
}

// ---------------------------------------------------------------- Keymap

const Entry = struct { mods: u32, mask: u32 = 0, level: u32, preserve: u32 = 0, preserve_mask: u32 = 0 };
const Type = struct { name: []const u8, mods: u32 = 0, mask: u32 = 0, entries: std.ArrayList(Entry) = .empty };
const Group = struct { type_name: ?[]const u8 = null, type: ?*const Type = null, levels: std.ArrayList([]const u32) = .empty };
const Key = struct {
    defined: bool = false,
    groups: std.ArrayList(Group) = .empty,
    repeats: bool = false,
    explicit_repeat: bool = false,
    modmap: u32 = 0,
    vmods: u32 = 0,
};
const Match = enum { exactly, all, none, any, any_or_none };
const Interpret = struct { keysym: u32, match: Match, mods: u32, level_one: bool, virtual_mod: ?u32, repeat: bool };

pub const Keymap = struct {
    arena: std.heap.ArenaAllocator,
    mod_names: std.ArrayList([]const u8) = .empty,
    mapping: [max_mods]u32 = @splat(0),
    types: std.ArrayList(Type) = .empty,
    /// Indexed by XKB keycode (evdev code + 8).
    keys: []Key = &.{},
    names: std.StringHashMapUnmanaged(u32) = .empty,
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    interprets: std.ArrayList(Interpret) = .empty,

    pub fn parse(gpa: std.mem.Allocator, source: []const u8) !*Keymap {
        const self = try gpa.create(Keymap);
        self.* = .{ .arena = .init(gpa) };
        errdefer self.deinit();
        const a = self.arena.allocator();
        for (real_mods) |name| try self.mod_names.append(a, name);
        const tokens = try tokenize(a, source);
        if (tokens.len < 2 or !std.mem.eql(u8, tokens[0].text, "xkb_keymap")) return error.InvalidKeymap;
        const open = indexOfPunct(tokens, '{') orelse return error.InvalidKeymap;
        var sections = Splitter{ .tokens = try braced(tokens, open), .separator = ';' };
        var symbols: ?[]const Token = null;
        var compat: ?[]const Token = null;
        var types: ?[]const Token = null;
        while (sections.next()) |section| {
            if (section.len == 0) continue;
            const body_start = indexOfPunct(section, '{') orelse continue;
            const body = try braced(section, body_start);
            const name = section[0].text;
            if (std.mem.eql(u8, name, "xkb_keycodes")) try self.keycodes(body);
            if (std.mem.eql(u8, name, "xkb_types")) types = body;
            if (std.mem.eql(u8, name, "xkb_compatibility") or std.mem.eql(u8, name, "xkb_compat")) compat = body;
            if (std.mem.eql(u8, name, "xkb_symbols")) symbols = body;
        }
        // Virtual modifiers are declared in types and compat before use.
        if (types) |body| try self.typesSection(body);
        if (compat) |body| try self.compatSection(body);
        if (symbols) |body| try self.symbolsSection(body);
        try self.derive();
        return self;
    }

    pub fn deinit(self: *Keymap) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn keycodes(self: *Keymap, body: []const Token) !void {
        const a = self.arena.allocator();
        var max: u32 = 255;
        var statements = Splitter{ .tokens = body, .separator = ';' };
        while (statements.next()) |statement| {
            if (statement.len == 4 and statement[0].kind == .ident and std.mem.eql(u8, statement[0].text, "alias") and statement[1].kind == .keyname and statement[3].kind == .keyname) {
                try self.aliases.put(a, statement[1].text, statement[3].text);
            } else if (statement.len == 3 and statement[0].kind == .keyname and statement[2].kind == .number) {
                const code = try std.fmt.parseInt(u32, statement[2].text, 0);
                if (code > 0xffff) return error.InvalidKeymap;
                max = @max(max, code);
                try self.names.put(a, statement[0].text, code);
            }
        }
        // A later keycodes section keeps the names of earlier ones valid.
        var names = self.names.valueIterator();
        while (names.next()) |code| max = @max(max, code.*);
        self.keys = try a.alloc(Key, max + 1);
        @memset(self.keys, .{});
    }

    fn keycode(self: *const Keymap, name: []const u8) ?u32 {
        if (self.names.get(name)) |code| return code;
        if (self.aliases.get(name)) |real| return self.names.get(real);
        return null;
    }

    /// virtual_modifiers A,B=0x4000,…
    fn virtualModifiers(self: *Keymap, statement: []const Token) !void {
        var items = Splitter{ .tokens = statement[1..], .separator = ',' };
        while (items.next()) |item| {
            if (item.len == 0 or item[0].kind != .ident) continue;
            const index = for (self.mod_names.items, 0..) |name, i| {
                if (std.mem.eql(u8, name, item[0].text)) break i;
            } else blk: {
                if (self.mod_names.items.len == max_mods) return error.InvalidKeymap;
                try self.mod_names.append(self.arena.allocator(), item[0].text);
                break :blk self.mod_names.items.len - 1;
            };
            if (item.len >= 3 and isPunct(item[1], '=')) self.mapping[index] = try self.modMask(item[2..]);
        }
    }

    /// A modifier expression such as Shift+LevelThree, none, all or a number.
    fn modMask(self: *const Keymap, tokens: []const Token) !u32 {
        var mask: u32 = 0;
        var terms = Splitter{ .tokens = tokens, .separator = '+' };
        while (terms.next()) |term| {
            if (term.len != 1) return error.InvalidKeymap;
            const text = term[0].text;
            if (term[0].kind == .number) {
                mask |= try std.fmt.parseInt(u32, text, 0);
            } else if (std.ascii.eqlIgnoreCase(text, "none")) {} else if (std.ascii.eqlIgnoreCase(text, "all")) {
                mask |= 0xff;
            } else {
                const index = for (self.mod_names.items, 0..) |name, i| {
                    if (std.ascii.eqlIgnoreCase(name, text)) break i;
                } else return error.InvalidKeymap;
                mask |= @as(u32, 1) << @intCast(index);
            }
        }
        return mask;
    }

    fn level(token: []const Token) !u32 {
        if (token.len != 1) return error.InvalidKeymap;
        const text = token[0].text;
        const digits = if (std.ascii.startsWithIgnoreCase(text, "level")) text[5..] else text;
        const value = try std.fmt.parseInt(u32, digits, 10);
        if (value == 0 or value > 256) return error.InvalidKeymap;
        return value - 1;
    }

    fn typesSection(self: *Keymap, body: []const Token) !void {
        const a = self.arena.allocator();
        var statements = Splitter{ .tokens = body, .separator = ';' };
        while (statements.next()) |statement| {
            if (statement.len == 0 or statement[0].kind != .ident) continue;
            if (std.mem.eql(u8, statement[0].text, "virtual_modifiers")) {
                try self.virtualModifiers(statement);
                continue;
            }
            if (!std.mem.eql(u8, statement[0].text, "type") or statement.len < 3 or statement[1].kind != .string) continue;
            var key_type: Type = .{ .name = statement[1].text };
            var fields = Splitter{ .tokens = try braced(statement, 2), .separator = ';' };
            while (fields.next()) |field| {
                const eq = indexOfPunct(field, '=') orelse continue;
                if (eq == 0) continue;
                const name = field[0].text;
                const value = field[eq + 1 ..];
                if (std.ascii.eqlIgnoreCase(name, "modifiers")) {
                    key_type.mods = try self.modMask(value);
                } else if (std.ascii.eqlIgnoreCase(name, "map") or std.ascii.eqlIgnoreCase(name, "preserve")) {
                    if (eq < 3 or !isPunct(field[1], '[')) return error.InvalidKeymap;
                    const mods = try self.modMask(field[2 .. eq - 1]);
                    const existing = for (key_type.entries.items) |*entry| {
                        if (entry.mods == mods) break entry;
                    } else blk: {
                        try key_type.entries.append(a, .{ .mods = mods, .level = 0 });
                        break :blk &key_type.entries.items[key_type.entries.items.len - 1];
                    };
                    if (std.ascii.eqlIgnoreCase(name, "map")) existing.level = try level(value) else existing.preserve = try self.modMask(value);
                }
            }
            try self.types.append(a, key_type);
        }
    }

    fn compatSection(self: *Keymap, body: []const Token) !void {
        const a = self.arena.allocator();
        var default_level_one = false;
        var default_repeat = true;
        var collected: std.ArrayList(Interpret) = .empty;
        var statements = Splitter{ .tokens = body, .separator = ';' };
        while (statements.next()) |statement| {
            if (statement.len == 0 or statement[0].kind != .ident) continue;
            const head = statement[0].text;
            if (std.mem.eql(u8, head, "virtual_modifiers")) {
                try self.virtualModifiers(statement);
            } else if (std.mem.eql(u8, head, "interpret") and statement.len >= 3 and isPunct(statement[1], '.')) {
                const eq = indexOfPunct(statement, '=') orelse continue;
                if (std.ascii.eqlIgnoreCase(statement[2].text, "useModMapMods")) default_level_one = isLevelOne(statement[eq + 1 ..]);
                if (std.ascii.eqlIgnoreCase(statement[2].text, "repeat")) default_repeat = try boolean(statement[eq + 1 ..]);
            } else if (std.mem.eql(u8, head, "interpret")) {
                const open = indexOfPunct(statement, '{') orelse continue;
                var interp: Interpret = .{ .keysym = NoSymbol, .match = .any_or_none, .mods = 0xff, .level_one = default_level_one, .virtual_mod = null, .repeat = default_repeat };
                const header = statement[1..open];
                if (header.len == 0) return error.InvalidKeymap;
                if (!std.ascii.eqlIgnoreCase(header[0].text, "Any")) interp.keysym = try self.keysymToken(header[0]);
                if (header.len >= 2 and isPunct(header[1], '+')) {
                    const predicate = header[2..];
                    const paren = indexOfPunct(predicate, '(');
                    if (paren) |p| {
                        if (p == 0 or p + 2 > predicate.len or !isPunct(predicate[predicate.len - 1], ')')) return error.InvalidKeymap;
                        interp.match = try matchName(predicate[0].text);
                        interp.mods = try self.modMask(predicate[p + 1 .. predicate.len - 1]);
                    } else {
                        interp.match = .exactly;
                        interp.mods = try self.modMask(predicate);
                    }
                }
                var fields = Splitter{ .tokens = try braced(statement, open), .separator = ';' };
                while (fields.next()) |field| {
                    const eq = indexOfPunct(field, '=') orelse continue;
                    if (eq == 0) continue;
                    const name = field[0].text;
                    const value = field[eq + 1 ..];
                    if (std.ascii.eqlIgnoreCase(name, "useModMapMods")) interp.level_one = isLevelOne(value);
                    if (std.ascii.eqlIgnoreCase(name, "repeat")) interp.repeat = try boolean(value);
                    if (std.ascii.eqlIgnoreCase(name, "virtualModifier") or std.ascii.eqlIgnoreCase(name, "virtualMod")) {
                        const mask = try self.modMask(value);
                        if (mask != 0) interp.virtual_mod = @ctz(mask);
                    }
                }
                try collected.append(a, interp);
            }
        }
        // Most specific first, as xkbcommon's compat compiler orders them.
        for ([_]bool{ true, false }) |with_symbol| {
            for ([_]Match{ .exactly, .all, .none, .any, .any_or_none }) |match| {
                for (collected.items) |interp| {
                    if ((interp.keysym != NoSymbol) == with_symbol and interp.match == match) try self.interprets.append(a, interp);
                }
            }
        }
    }

    fn matchName(name: []const u8) !Match {
        if (std.ascii.eqlIgnoreCase(name, "NoneOf")) return .none;
        if (std.ascii.eqlIgnoreCase(name, "AnyOfOrNone")) return .any_or_none;
        if (std.ascii.eqlIgnoreCase(name, "AnyOf")) return .any;
        if (std.ascii.eqlIgnoreCase(name, "AllOf")) return .all;
        if (std.ascii.eqlIgnoreCase(name, "Exactly")) return .exactly;
        return error.InvalidKeymap;
    }
    fn isLevelOne(value: []const Token) bool {
        return value.len == 1 and (std.ascii.eqlIgnoreCase(value[0].text, "level1") or std.ascii.eqlIgnoreCase(value[0].text, "levelone"));
    }
    fn boolean(value: []const Token) !bool {
        if (value.len != 1) return error.InvalidKeymap;
        for ([_][]const u8{ "true", "yes", "on" }) |word| if (std.ascii.eqlIgnoreCase(value[0].text, word)) return true;
        for ([_][]const u8{ "false", "no", "off" }) |word| if (std.ascii.eqlIgnoreCase(value[0].text, word)) return false;
        return error.InvalidKeymap;
    }

    fn keysymToken(_: *const Keymap, token: Token) !u32 {
        if (token.kind == .number) {
            // Single digits name the digit keysyms; other numbers are keysym values.
            if (token.text.len == 1) return '0' + @as(u32, token.text[0] - '0');
            return std.fmt.parseInt(u32, token.text, 0);
        }
        if (token.kind != .ident) return error.InvalidKeymap;
        if (std.mem.eql(u8, token.text, "NoSymbol")) return NoSymbol;
        return keysymFromName(token.text) orelse NoSymbol;
    }

    /// [ a, A, { b, c } ]: one keysym list per level.
    fn levels(self: *Keymap, tokens: []const Token) !std.ArrayList([]const u32) {
        const a = self.arena.allocator();
        var result: std.ArrayList([]const u32) = .empty;
        var items = Splitter{ .tokens = tokens, .separator = ',' };
        while (items.next()) |item| {
            if (item.len == 0) continue;
            if (isPunct(item[0], '{')) {
                var syms: std.ArrayList(u32) = .empty;
                var inner = Splitter{ .tokens = try braced(item, 0), .separator = ',' };
                while (inner.next()) |sym| if (sym.len == 1) {
                    const value = try self.keysymToken(sym[0]);
                    if (value != NoSymbol) try syms.append(a, value);
                };
                try result.append(a, syms.items);
            } else {
                if (item.len != 1) return error.InvalidKeymap;
                const value = try self.keysymToken(item[0]);
                try result.append(a, if (value == NoSymbol) &.{} else try a.dupe(u32, &[_]u32{value}));
            }
        }
        return result;
    }

    fn group(key: *Key, a: std.mem.Allocator, index: usize) !*Group {
        while (key.groups.items.len <= index) try key.groups.append(a, .{});
        return &key.groups.items[index];
    }

    /// [Group2] or [2] → 1.
    fn groupIndex(tokens: []const Token) !usize {
        if (tokens.len != 3 or !isPunct(tokens[0], '[')) return error.InvalidKeymap;
        const text = tokens[1].text;
        const digits = if (std.ascii.startsWithIgnoreCase(text, "group")) text[5..] else text;
        const value = try std.fmt.parseInt(usize, digits, 10);
        if (value == 0 or value > 4) return error.InvalidKeymap;
        return value - 1;
    }

    fn symbolsSection(self: *Keymap, body: []const Token) !void {
        const a = self.arena.allocator();
        var statements = Splitter{ .tokens = body, .separator = ';' };
        while (statements.next()) |statement| {
            if (statement.len < 3 or statement[0].kind != .ident) continue;
            if (std.mem.eql(u8, statement[0].text, "key") and statement[1].kind == .keyname) {
                const code = self.keycode(statement[1].text) orelse continue;
                if (code >= self.keys.len) continue;
                const key = &self.keys[code];
                key.defined = true;
                const open = indexOfPunct(statement, '{') orelse return error.InvalidKeymap;
                var fields = Splitter{ .tokens = try braced(statement, open), .separator = ',' };
                var implicit: usize = 0;
                while (fields.next()) |field| {
                    if (field.len == 0) continue;
                    if (isPunct(field[0], '[')) {
                        (try group(key, a, implicit)).levels = try self.levels(try braced(field, 0));
                        implicit += 1;
                        continue;
                    }
                    const eq = indexOfPunct(field, '=') orelse continue;
                    const name = field[0].text;
                    const value = field[eq + 1 ..];
                    if (std.ascii.eqlIgnoreCase(name, "type")) {
                        if (value.len != 1 or value[0].kind != .string) return error.InvalidKeymap;
                        if (eq == 1) {
                            // A key-wide type applies to every group.
                            for (0..4) |i| {
                                const target = try group(key, a, i);
                                if (target.type_name == null) target.type_name = value[0].text;
                            }
                        } else (try group(key, a, try groupIndex(field[1..eq]))).type_name = value[0].text;
                    } else if (std.ascii.eqlIgnoreCase(name, "symbols")) {
                        if (value.len == 0 or !isPunct(value[0], '[')) return error.InvalidKeymap;
                        (try group(key, a, try groupIndex(field[1..eq]))).levels = try self.levels(try braced(value, 0));
                    } else if (std.ascii.eqlIgnoreCase(name, "repeat") or std.ascii.eqlIgnoreCase(name, "repeats")) {
                        key.explicit_repeat = true;
                        key.repeats = try boolean(value);
                    } else if (std.ascii.eqlIgnoreCase(name, "vmods") or std.ascii.eqlIgnoreCase(name, "virtualMods") or std.ascii.eqlIgnoreCase(name, "virtualModifiers")) {
                        key.vmods = try self.modMask(value);
                    }
                }
                // Trailing groups with neither symbols nor an explicit type do not exist.
                while (key.groups.items.len > 0 and key.groups.items[key.groups.items.len - 1].levels.items.len == 0) _ = key.groups.pop();
            } else if (std.mem.eql(u8, statement[0].text, "modifier_map")) {
                const mask = try self.modMask(statement[1..2]);
                const open = indexOfPunct(statement, '{') orelse return error.InvalidKeymap;
                var members = Splitter{ .tokens = try braced(statement, open), .separator = ',' };
                while (members.next()) |member| {
                    if (member.len != 1) continue;
                    if (member[0].kind == .keyname) {
                        if (self.keycode(member[0].text)) |code| if (code < self.keys.len) {
                            self.keys[code].modmap |= mask;
                        };
                    } else {
                        // A keysym names the first key that produces it.
                        const sym = try self.keysymToken(member[0]);
                        search: for (self.keys) |*key| for (key.groups.items) |g| for (g.levels.items) |syms| for (syms) |s| if (s == sym) {
                            key.modmap |= mask;
                            break :search;
                        };
                    }
                }
            }
        }
    }

    fn findType(self: *const Keymap, name: []const u8) ?*const Type {
        for (self.types.items) |*t| if (std.mem.eql(u8, t.name, name)) return t;
        return null;
    }

    /// xkbcommon's FindAutomaticType.
    fn automaticType(g: *const Group) []const u8 {
        const width = g.levels.items.len;
        if (width <= 1) return "ONE_LEVEL";
        const sym = struct {
            fn at(list: []const []const u32, i: usize) u32 {
                return if (i < list.len and list[i].len > 0) list[i][0] else NoSymbol;
            }
        }.at;
        const items = g.levels.items;
        const alphabetic = isLower(sym(items, 0)) and isUpper(sym(items, 1));
        const keypad = isKeypad(sym(items, 0)) or isKeypad(sym(items, 1));
        if (width == 2) return if (alphabetic) "ALPHABETIC" else if (keypad) "KEYPAD" else "TWO_LEVEL";
        if (alphabetic) return if (isLower(sym(items, 2)) and isUpper(sym(items, 3))) "FOUR_LEVEL_ALPHABETIC" else "FOUR_LEVEL_SEMIALPHABETIC";
        return if (keypad) "FOUR_LEVEL_KEYPAD" else "FOUR_LEVEL";
    }

    fn findInterpret(self: *const Keymap, key: *const Key, sym: u32, level_index: usize) ?*const Interpret {
        for (self.interprets.items) |*interp| {
            if (interp.keysym != sym and interp.keysym != NoSymbol) continue;
            const mods = if (interp.level_one and level_index != 0) 0 else key.modmap;
            const found = switch (interp.match) {
                .none => interp.mods & mods == 0,
                .any_or_none => mods == 0 or interp.mods & mods != 0,
                .any => interp.mods & mods != 0,
                .all => interp.mods & mods == interp.mods,
                .exactly => interp.mods == mods,
            };
            if (found) return interp;
        }
        return null;
    }

    fn resolve(self: *const Keymap, mods: u32) u32 {
        var mask = mods & 0xff;
        var rest = mods & ~@as(u32, 0xff);
        while (rest != 0) : (rest &= rest - 1) mask |= self.mapping[@ctz(rest)];
        return mask;
    }

    fn derive(self: *Keymap) !void {
        for (self.keys) |*key| {
            if (!key.defined) continue;
            for (key.groups.items) |*g| {
                const name = g.type_name orelse automaticType(g);
                g.type = self.findType(name) orelse self.findType("ONE_LEVEL") orelse return error.InvalidKeymap;
            }
            // Interprets set repeat and virtual modifiers from the keysyms.
            var vmodmap = key.vmods;
            for (key.groups.items, 0..) |g, group_index| for (g.levels.items, 0..) |syms, level_index| {
                for (syms) |sym| {
                    const interp = self.findInterpret(key, sym, level_index);
                    const repeat = if (interp) |i| i.repeat else true;
                    if (group_index == 0 and level_index == 0 and !key.explicit_repeat and repeat) key.repeats = true;
                    if (interp) |i| if ((group_index == 0 and level_index == 0) or !i.level_one) {
                        if (i.virtual_mod) |v| vmodmap |= @as(u32, 1) << @intCast(v);
                    };
                }
            };
            key.vmods = vmodmap;
        }
        for (self.keys) |key| {
            var rest = key.vmods & ~@as(u32, 0xff);
            while (rest != 0) : (rest &= rest - 1) self.mapping[@ctz(rest)] |= key.modmap;
        }
        for (self.types.items) |*t| {
            t.mask = self.resolve(t.mods);
            for (t.entries.items) |*entry| {
                entry.mask = self.resolve(entry.mods);
                entry.preserve_mask = self.resolve(entry.preserve);
            }
        }
    }

    pub fn repeats(self: *const Keymap, code: u32) bool {
        return code < self.keys.len and self.keys[code].defined and self.keys[code].repeats;
    }

    /// The real modifiers a key sets through modifier_map, for compositors
    /// tracking modifier state from key presses.
    /// How many layouts (groups) the keymap has.
    pub fn groupCount(self: *const Keymap) u32 {
        var count: usize = 1;
        for (self.keys) |key| count = @max(count, key.groups.items.len);
        return @intCast(count);
    }

    pub fn modifierMask(self: *const Keymap, code: u32) u32 {
        return if (code < self.keys.len and self.keys[code].defined) self.keys[code].modmap else 0;
    }
};

// ---------------------------------------------------------------- State

pub const State = struct {
    keymap: *const Keymap,
    mods: u32 = 0,
    group: u32 = 0,

    pub fn update(self: *State, depressed: u32, latched: u32, locked: u32, group: u32) void {
        self.mods = depressed | latched | locked;
        self.group = group;
    }

    /// Whether a modifier (by name, real or virtual) is in effect.
    pub fn active(self: *const State, name: []const u8) bool {
        for (self.keymap.mod_names.items, 0..) |mod, i| if (std.mem.eql(u8, mod, name)) {
            const mask = self.keymap.resolve(@as(u32, 1) << @intCast(i));
            return mask != 0 and self.mods & mask == mask;
        };
        return false;
    }

    const Lookup = struct { syms: []const u32, consumed: u32 };
    fn lookup(self: *const State, code: u32) ?Lookup {
        if (code >= self.keymap.keys.len) return null;
        const key = &self.keymap.keys[code];
        if (!key.defined or key.groups.items.len == 0) return null;
        const g = &key.groups.items[self.group % key.groups.items.len];
        const key_type = g.type.?;
        const mods = self.mods & key_type.mask;
        var level_index: usize = 0;
        var preserve: u32 = 0;
        for (key_type.entries.items) |entry| {
            // Entries naming only unmapped virtual modifiers never match.
            if (entry.mods != 0 and entry.mask == 0) continue;
            if (entry.mask == mods) {
                level_index = entry.level;
                preserve = entry.preserve_mask;
                break;
            }
        }
        if (level_index >= g.levels.items.len) return .{ .syms = &.{}, .consumed = key_type.mask & ~preserve };
        return .{ .syms = g.levels.items[level_index], .consumed = key_type.mask & ~preserve };
    }

    fn capsActive(self: *const State, consumed: u32) bool {
        return self.mods & lock_mask != 0 and consumed & lock_mask == 0;
    }

    /// The single keysym a key produces, after the Caps Lock transformation.
    pub fn keysym(self: *const State, code: u32) u32 {
        const found = self.lookup(code) orelse return NoSymbol;
        if (found.syms.len != 1) return NoSymbol;
        return if (self.capsActive(found.consumed)) toUpperKeysym(found.syms[0]) else found.syms[0];
    }

    /// UTF-8 for a key, or an empty slice.
    pub fn utf8(self: *const State, code: u32, buffer: []u8) []const u8 {
        const found = self.lookup(code) orelse return "";
        var length: usize = 0;
        for (found.syms) |raw| {
            const sym = if (self.capsActive(found.consumed)) toUpperKeysym(raw) else raw;
            const cp = toUnicode(sym);
            if (cp == 0) return "";
            if (length + 4 > buffer.len) return "";
            length += std.unicode.utf8Encode(cp, buffer[length..]) catch return "";
        }
        return buffer[0..length];
    }
};

// ---------------------------------------------------------------- Compose

pub const Status = enum { nothing, composing, composed, cancelled };

/// A Compose table (XCompose format) as a trie of keysym sequences.
pub const ComposeTable = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    const Node = struct { leaf: bool = false, text: []const u8 = "", keysym: u32 = NoSymbol };

    pub fn init(gpa: std.mem.Allocator) !*ComposeTable {
        const self = try gpa.create(ComposeTable);
        self.* = .{ .arena = .init(gpa) };
        try self.nodes.append(self.arena.allocator(), .{});
        return self;
    }
    pub fn deinit(self: *ComposeTable) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn child(self: *const ComposeTable, node: u32, sym: u32) ?u32 {
        return self.edges.get(@as(u64, node) << 32 | sym);
    }

    fn add(self: *ComposeTable, sequence: []const u32, text: []const u8, keysym: u32) !void {
        const a = self.arena.allocator();
        var node: u32 = 0;
        for (sequence) |sym| {
            // A longer sequence replaces a shorter one that is its prefix.
            self.nodes.items[node].leaf = false;
            const entry = try self.edges.getOrPut(a, @as(u64, node) << 32 | sym);
            if (!entry.found_existing) {
                entry.value_ptr.* = @intCast(self.nodes.items.len);
                try self.nodes.append(a, .{});
            }
            node = entry.value_ptr.*;
        }
        // A shorter sequence replaces the longer ones it prefixes.
        self.nodes.items[node] = .{ .leaf = true, .text = try a.dupe(u8, text), .keysym = keysym };
    }

    /// Loads the file chosen as xkbcommon does: $XCOMPOSEFILE, the XDG and
    /// home XCompose files, then the locale's file under `locale_dir`.
    pub fn load(gpa: std.mem.Allocator, locale_dir: []const u8, locale: []const u8) ?*ComposeTable {
        const self = init(gpa) catch return null;
        const a = self.arena.allocator();
        const home = std.c.getenv("HOME");
        var candidates: [3]?[]const u8 = .{ null, null, null };
        if (std.c.getenv("XCOMPOSEFILE")) |path| candidates[0] = std.mem.span(path);
        if (std.c.getenv("XDG_CONFIG_HOME")) |config| {
            if (config[0] == '/') candidates[1] = std.fmt.allocPrint(a, "{s}/XCompose", .{config}) catch null;
        } else if (home) |h| candidates[1] = std.fmt.allocPrint(a, "{s}/.config/XCompose", .{h}) catch null;
        if (home) |h| candidates[2] = std.fmt.allocPrint(a, "{s}/.XCompose", .{h}) catch null;
        const context: Context = .{ .locale_dir = locale_dir, .locale = locale };
        for (candidates) |candidate| if (candidate) |path| {
            if (self.readFile(path, context, 0)) return self;
        };
        if (context.localeFile(a)) |path| if (self.readFile(path, context, 0)) return self;
        self.deinit();
        return null;
    }

    const Context = struct {
        locale_dir: []const u8,
        locale: []const u8,

        fn localeFile(self: Context, a: std.mem.Allocator) ?[]const u8 {
            var name = self.locale;
            if (std.mem.eql(u8, name, "C") or std.mem.eql(u8, name, "POSIX")) name = "en_US.UTF-8";
            if (self.lookup(a, "locale.alias", name, false)) |alias| name = alias;
            const file = self.lookup(a, "compose.dir", name, true) orelse self.lookup(a, "compose.dir", "en_US.UTF-8", true) orelse return null;
            if (file.len > 0 and file[0] == '/') return file;
            return std.fmt.allocPrint(a, "{s}/{s}", .{ self.locale_dir, file }) catch null;
        }

        /// compose.dir maps right to left (file ← locale); locale.alias left to right.
        fn lookup(self: Context, a: std.mem.Allocator, registry: []const u8, name: []const u8, right_to_left: bool) ?[]const u8 {
            const path = std.fmt.allocPrint(a, "{s}/{s}", .{ self.locale_dir, registry }) catch return null;
            const data = readAll(a, path) orelse return null;
            var lines = std.mem.splitScalar(u8, data, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0 or line[0] == '#') continue;
                const split = std.mem.indexOfAny(u8, line, " \t:") orelse continue;
                const left = line[0..split];
                // Either side of the colon may have spaces: "en_US.utf8 : en_US.UTF-8".
                var rest = std.mem.trimStart(u8, line[split..], " \t");
                if (rest.len > 0 and rest[0] == ':') rest = rest[1..];
                rest = std.mem.trim(u8, rest, " \t");
                const right = rest[0 .. std.mem.indexOfAny(u8, rest, " \t") orelse rest.len];
                if (right_to_left and std.mem.eql(u8, right, name)) return left;
                if (!right_to_left and std.mem.eql(u8, left, name)) return right;
            }
            return null;
        }
    };

    fn readAll(a: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const z = a.dupeSentinel(u8, path, 0) catch return null;
        defer a.free(z);
        const fd = std.c.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) return null;
        defer _ = std.c.close(fd);
        var data: std.ArrayList(u8) = .empty;
        while (data.items.len < 8 * 1024 * 1024) {
            data.ensureUnusedCapacity(a, 64 * 1024) catch {
                data.deinit(a);
                return null;
            };
            const spare = data.unusedCapacitySlice();
            const got = std.c.read(fd, spare.ptr, spare.len);
            if (got < 0) {
                if (std.c._errno().* == 4) continue; // EINTR
                data.deinit(a);
                return null;
            }
            if (got == 0) return data.toOwnedSlice(a) catch {
                data.deinit(a);
                return null;
            };
            data.items.len += @intCast(got);
        }
        data.deinit(a);
        return null;
    }

    fn readFile(self: *ComposeTable, path: []const u8, context: Context, depth: u32) bool {
        if (depth > 8) return false;
        // Parsed results are copied into the table, so the file itself is temporary.
        const gpa = self.arena.child_allocator;
        const data = readAll(gpa, path) orelse return false;
        defer gpa.free(data);
        self.parse(data, context, depth) catch return false;
        return true;
    }

    fn parse(self: *ComposeTable, data: []const u8, context: Context, depth: u32) !void {
        const a = self.arena.allocator();
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (std.mem.startsWith(u8, line, "include")) {
                const start = std.mem.indexOfScalar(u8, line, '"') orelse continue;
                const end = std.mem.indexOfScalarPos(u8, line, start + 1, '"') orelse continue;
                const path = expand(a, line[start + 1 .. end], context) orelse continue;
                _ = self.readFile(path, context, depth + 1);
                continue;
            }
            const colon = colonOutsideString(line) orelse continue;
            var sequence: [16]u32 = undefined;
            var count: usize = 0;
            var lhs = line[0..colon];
            var valid = true;
            while (std.mem.indexOfScalar(u8, lhs, '<')) |open| {
                const close = std.mem.indexOfScalarPos(u8, lhs, open, '>') orelse break;
                const sym = keysymFromName(lhs[open + 1 .. close]) orelse {
                    valid = false;
                    break;
                };
                if (count == sequence.len) {
                    valid = false;
                    break;
                }
                sequence[count] = sym;
                count += 1;
                lhs = lhs[close + 1 ..];
            }
            if (!valid or count == 0) continue;
            line = std.mem.trim(u8, line[colon + 1 ..], " \t");
            var text: []const u8 = "";
            if (line.len > 0 and line[0] == '"') {
                const parsed = try unescape(a, line) orelse continue;
                text = parsed.text;
                line = std.mem.trim(u8, parsed.rest, " \t");
            }
            var result: u32 = NoSymbol;
            if (line.len > 0 and line[0] != '#') {
                const end = std.mem.indexOfAny(u8, line, " \t#") orelse line.len;
                result = keysymFromName(line[0..end]) orelse NoSymbol;
            }
            if (text.len == 0 and result == NoSymbol) continue;
            if (!std.unicode.utf8ValidateSlice(text)) continue;
            try self.add(sequence[0..count], text, result);
        }
    }

    fn colonOutsideString(line: []const u8) ?usize {
        var quoted = false;
        for (line, 0..) |c, i| {
            if (c == '"') quoted = !quoted;
            if (c == ':' and !quoted) return i;
        }
        return null;
    }

    fn unescape(a: std.mem.Allocator, line: []const u8) !?struct { text: []const u8, rest: []const u8 } {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (c == '"') return .{ .text = out.items, .rest = line[i + 1 ..] };
            if (c != '\\' or i + 1 >= line.len) {
                try out.append(a, c);
                continue;
            }
            i += 1;
            switch (line[i]) {
                'x', 'X' => {
                    var end = i + 1;
                    while (end < line.len and end < i + 3 and std.ascii.isHex(line[end])) end += 1;
                    try out.append(a, std.fmt.parseInt(u8, line[i + 1 .. end], 16) catch return null);
                    i = end - 1;
                },
                '0'...'7' => {
                    var end = i;
                    while (end < line.len and end < i + 3 and line[end] >= '0' and line[end] <= '7') end += 1;
                    try out.append(a, std.fmt.parseInt(u8, line[i..end], 8) catch return null);
                    i = end - 1;
                },
                'n' => try out.append(a, '\n'),
                else => try out.append(a, line[i]),
            }
        }
        return null;
    }

    /// %% → %, %H → $HOME, %L → the locale's Compose file, %S → the system directory.
    fn expand(a: std.mem.Allocator, path: []const u8, context: Context) ?[]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            if (path[i] != '%' or i + 1 >= path.len) {
                out.append(a, path[i]) catch return null;
                continue;
            }
            i += 1;
            const piece: []const u8 = switch (path[i]) {
                '%' => "%",
                'H' => std.mem.span(std.c.getenv("HOME") orelse return null),
                'L' => context.localeFile(a) orelse return null,
                'S' => context.locale_dir,
                else => return null,
            };
            out.appendSlice(a, piece) catch return null;
        }
        return out.items;
    }
};

pub const Compose = struct {
    table: *const ComposeTable,
    node: u32 = 0,
    previous: u32 = 0,

    pub fn feed(self: *Compose, sym: u32) Status {
        if (isModifier(sym)) return self.status();
        // A completed sequence starts over from the root.
        const from: u32 = if (self.table.nodes.items[self.node].leaf) 0 else self.node;
        self.previous = from;
        self.node = self.table.child(from, sym) orelse 0;
        return self.status();
    }
    fn status(self: *const Compose) Status {
        if (self.node == 0) return if (self.previous != 0) .cancelled else .nothing;
        return if (self.table.nodes.items[self.node].leaf) .composed else .composing;
    }
    pub fn reset(self: *Compose) void {
        self.node = 0;
        self.previous = 0;
    }
    /// The composed text, after `feed` returned `.composed`.
    pub fn utf8(self: *const Compose, buffer: []u8) []const u8 {
        const node = self.table.nodes.items[self.node];
        if (node.text.len > 0) return if (node.text.len <= buffer.len) blk: {
            @memcpy(buffer[0..node.text.len], node.text);
            break :blk buffer[0..node.text.len];
        } else "";
        const cp = toUnicode(node.keysym);
        if (cp == 0 or buffer.len < 4) return "";
        return buffer[0 .. std.unicode.utf8Encode(cp, buffer) catch return ""];
    }
};

// ---------------------------------------------------------------- Tests

const test_keymap =
    \\xkb_keymap {
    \\xkb_keycodes "test" {
    \\    minimum = 8;
    \\    maximum = 255;
    \\    <AD03> = 26; <AC01> = 38; <LFSH> = 50; <NMLK> = 77; <KP7> = 79; <LVL3> = 92; <AE02> = 11; <CAPS> = 66;
    \\    alias <LatA> = <AC01>;
    \\    indicator 1 = "Caps Lock";
    \\};
    \\xkb_types "test" {
    \\    virtual_modifiers NumLock,LevelThree,Hyper=0x4000;
    \\    type "ONE_LEVEL" { modifiers= none; level_name[1]= "Any"; };
    \\    type "TWO_LEVEL" { modifiers= Shift; map[Shift]= 2; };
    \\    type "ALPHABETIC" { modifiers= Shift+Lock; map[Shift]= 2; map[Lock]= 2; };
    \\    type "KEYPAD" { modifiers= Shift+NumLock; map[None]= 1; map[Shift]= 2; map[NumLock]= 2; map[Shift+NumLock]= 1; };
    \\    type "FOUR_LEVEL_ALPHABETIC" { modifiers= Shift+Lock+LevelThree; map[Shift]= 2; map[Lock]= 2; map[LevelThree]= 3; map[Shift+LevelThree]= 4; map[Lock+LevelThree]= 4; map[Lock+Shift+LevelThree]= 3; };
    \\};
    \\xkb_compatibility "test" {
    \\    virtual_modifiers NumLock,LevelThree,Hyper=0x4000;
    \\    interpret.useModMapMods= AnyLevel;
    \\    interpret.repeat= False;
    \\    interpret Num_Lock+AnyOf(all) { virtualModifier= NumLock; action= LockMods(modifiers=NumLock); };
    \\    interpret ISO_Level3_Shift+AnyOf(all) { virtualModifier= LevelThree; useModMapMods=level1; action= SetMods(modifiers=LevelThree,clearLocks); };
    \\    interpret Any+AnyOf(all) { action= SetMods(modifiers=modMapMods,clearLocks); };
    \\    interpret KP_7+AnyOfOrNone(all) { repeat= True; };
    \\};
    \\xkb_symbols "test" {
    \\    key <AD03> { [ e, E, eacute, Eacute ] };
    \\    key <LatA> { [ a, A ] };
    \\    key <AE02> { [ 2, at ] };
    \\    key <LFSH> { [ Shift_L ] };
    \\    key <NMLK> { [ Num_Lock ] };
    \\    key <KP7> { [ KP_Home, KP_7 ] };
    \\    key <LVL3> { type= "ONE_LEVEL", symbols[1]= [ ISO_Level3_Shift ] };
    \\    key <CAPS> { repeat= Yes, [ { a, b } ] };
    \\    modifier_map Shift { <LFSH> };
    \\    modifier_map Mod2 { <NMLK> };
    \\    modifier_map Mod5 { ISO_Level3_Shift };
    \\};
    \\};
;

test "compiled keymaps choose levels from types, virtual modifiers and Caps Lock" {
    const keymap = try Keymap.parse(std.testing.allocator, test_keymap);
    defer keymap.deinit();
    var state: State = .{ .keymap = keymap };
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 'a'), state.keysym(38));
    try std.testing.expectEqualStrings("2", state.utf8(11, &buffer));
    state.update(1, 0, 0, 0); // Shift
    try std.testing.expectEqual(@as(u32, 'A'), state.keysym(38));
    try std.testing.expectEqualStrings("@", state.utf8(11, &buffer));
    // Lock is consumed by ALPHABETIC but transforms TWO_LEVEL symbols.
    state.update(0, 0, lock_mask, 0);
    try std.testing.expectEqualStrings("A", state.utf8(38, &buffer));
    try std.testing.expectEqualStrings("2", state.utf8(11, &buffer));
    // LevelThree maps to Mod5 through the interpret and modifier_map.
    state.update(1 << 7, 0, 0, 0);
    try std.testing.expectEqualStrings("é", state.utf8(26, &buffer));
    try std.testing.expect(state.active("LevelThree"));
    state.update(1 << 7 | 1, 0, 0, 0);
    try std.testing.expectEqualStrings("É", state.utf8(26, &buffer));
    // NumLock (Mod2) selects the keypad digit.
    state.update(0, 0, 1 << 4, 0);
    try std.testing.expectEqual(@as(u32, 0xffb7), state.keysym(79));
    state.update(0, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 0xff95), state.keysym(79));
    // Several keysyms on one level produce text but no single keysym.
    try std.testing.expectEqual(NoSymbol, state.keysym(66));
    try std.testing.expectEqualStrings("ab", state.utf8(66, &buffer));
    try std.testing.expect(keymap.repeats(38));
    try std.testing.expect(!keymap.repeats(50));
    try std.testing.expect(!keymap.repeats(77));
    try std.testing.expect(keymap.repeats(79));
    try std.testing.expect(keymap.repeats(66));
    try std.testing.expect(!keymap.repeats(200));
    try std.testing.expectError(error.InvalidKeymap, Keymap.parse(std.testing.allocator, "xkb_keymap { xkb_types { type \"X\" { modifiers= Unknown; }; }; };"));
}

test "keysym names and characters follow the X11 keysym headers" {
    try std.testing.expectEqual(@as(?u32, 0xff0d), keysymFromName("Return"));
    try std.testing.expectEqual(@as(?u32, 0x1008ff12), keysymFromName("XF86AudioMute"));
    try std.testing.expectEqual(@as(?u32, 0x10020ac), keysymFromName("U20AC"));
    try std.testing.expectEqual(@as(?u32, 'e'), keysymFromName("U0065"));
    try std.testing.expectEqual(@as(?u32, null), keysymFromName("NotAKeysym"));
    try std.testing.expectEqual(@as(u21, 0x0414), toUnicode(keysymFromName("Cyrillic_DE").?));
    try std.testing.expectEqual(@as(u21, 0x20ac), toUnicode(0x10020ac));
    try std.testing.expectEqual(@as(u21, 0), toUnicode(0x0100d800));
    try std.testing.expectEqual(@as(u21, 0x0d), toUnicode(0xff8d));
    try std.testing.expectEqual(@as(u21, 0), toUnicode(0xffe1));
}

test "compose sequences complete, cancel, ignore modifiers and override prefixes" {
    const table = try ComposeTable.init(std.testing.allocator);
    defer table.deinit();
    try table.parse(
        \\# comment
        \\<dead_acute> <e> : "é" eacute
        \\<Multi_key> <a> <e> : "æ"
        \\<Multi_key> <o> : "\x41\102" # escapes
        \\<Multi_key> <o> <o> : "°"
        \\<Multi_key> <U0063> <slash> : cent
        \\<dead_acute> <dead_acute> : "´"
        \\<dead_acute> <dead_acute> : "''"
    , .{ .locale_dir = "/nonexistent", .locale = "C" }, 0);
    var compose: Compose = .{ .table = table };
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(Status.nothing, compose.feed('x'));
    try std.testing.expectEqual(Status.composing, compose.feed(0xfe51));
    try std.testing.expectEqual(Status.composing, compose.feed(0xffe1)); // Shift_L is ignored.
    try std.testing.expectEqual(Status.composed, compose.feed('e'));
    try std.testing.expectEqualStrings("é", compose.utf8(&buffer));
    try std.testing.expectEqual(Status.composing, compose.feed(0xff20));
    try std.testing.expectEqual(Status.cancelled, compose.feed('z'));
    try std.testing.expectEqual(Status.nothing, compose.feed('z'));
    _ = compose.feed(0xff20);
    _ = compose.feed('o');
    try std.testing.expectEqual(Status.composed, compose.feed('o'));
    try std.testing.expectEqualStrings("°", compose.utf8(&buffer));
    compose.reset();
    _ = compose.feed(0xff20);
    _ = compose.feed('c');
    try std.testing.expectEqual(Status.composed, compose.feed('/'));
    try std.testing.expectEqualStrings("¢", compose.utf8(&buffer));
    compose.reset();
    _ = compose.feed(0xfe51);
    try std.testing.expectEqual(Status.composed, compose.feed(0xfe51));
    try std.testing.expectEqualStrings("''", compose.utf8(&buffer));
}

test "malformed keymaps fail instead of panicking" {
    const malformed = [_][]const u8{
        // A type without a body.
        "xkb_keymap { xkb_keycodes { <A> = 38; }; xkb_types { type \"X\" }; }; };",
        // An interpret predicate without its closing parenthesis.
        "xkb_keymap { xkb_keycodes { <A> = 38; }; xkb_compat { interpret Any+AnyOf( { }; }; };",
    };
    for (malformed) |text| {
        if (Keymap.parse(std.testing.allocator, text)) |keymap| keymap.deinit() else |_| {}
    }
    // A second, smaller keycodes section keeps keys named by the first.
    const keymap = try Keymap.parse(std.testing.allocator,
        \\xkb_keymap {
        \\  xkb_keycodes { <HIGH> = 400; };
        \\  xkb_keycodes { <A> = 38; };
        \\  xkb_types { type "ONE_LEVEL" { modifiers = none; level_name[Level1] = "Any"; }; };
        \\  xkb_symbols { key <HIGH> { [ a ] }; key <A> { [ b ] }; };
        \\};
    );
    defer keymap.deinit();
    var state: State = .{ .keymap = keymap };
    try std.testing.expectEqual(@as(u32, 'a'), state.keysym(400));
    try std.testing.expectEqual(@as(u32, 'b'), state.keysym(38));
}

test "locale aliases allow spaces around the colon" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "locale.alias", .data = "# comment\nen_US.utf8 : en_US.UTF-8\nde_DE.utf8:\tde_DE.UTF-8\n" });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const context: ComposeTable.Context = .{ .locale_dir = dir, .locale = "C" };
    try std.testing.expectEqualStrings("en_US.UTF-8", context.lookup(arena.allocator(), "locale.alias", "en_US.utf8", false).?);
    try std.testing.expectEqualStrings("de_DE.UTF-8", context.lookup(arena.allocator(), "locale.alias", "de_DE.utf8", false).?);
}
