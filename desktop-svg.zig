//! SVG rendering for icons and application artwork, independent of librsvg.
//! Supports shapes, paths, transforms, CSS (type, class and id selectors),
//! linear and radial gradients, patterns, clip paths, luminance masks, group
//! opacity, `use`, embedded PNG images, `feColorMatrix` filters and GTK's
//! symbolic icon recoloring. Text, markers and other filters are not drawn.
const std = @import("std");
const vec = @import("desktop-path.zig");
const png = @import("desktop-png.zig");

pub const Color = struct {
    rgb: u32,
    alpha: f64 = 1,

    pub const black: Color = .{ .rgb = 0 };
    fn channel(self: Color, shift: u5) f64 {
        return @as(f64, @floatFromInt((self.rgb >> shift) & 255)) / 255;
    }
    fn premultiplied(self: Color, opacity: f64) u32 {
        return vec.premultiply(self.channel(16), self.channel(8), self.channel(0), self.alpha * opacity);
    }
};

/// GTK's symbolic palette: shapes take `foreground` unless classed as
/// success, warning or error; a `stroke` class strokes instead of filling.
pub const Symbolic = struct {
    foreground: Color,
    success: Color = .{ .rgb = 0x4e9a06 },
    warning: Color = .{ .rgb = 0xf5793e },
    @"error": Color = .{ .rgb = 0xcc0000 },
};

pub const Options = struct {
    symbolic: ?Symbolic = null,
    opacity: f64 = 1,
};

const Attribute = struct { name: []const u8, value: []const u8 };

const Node = struct {
    name: []const u8,
    attributes: []Attribute = &.{},
    children: []*Node = &.{},
    text: []const u8 = "",

    fn get(self: *const Node, name: []const u8) ?[]const u8 {
        for (self.attributes) |attribute| if (std.mem.eql(u8, attribute.name, name)) return attribute.value;
        return null;
    }
    fn href(self: *const Node) ?[]const u8 {
        return self.get("href") orelse self.get("xlink:href");
    }
    fn hasClass(self: *const Node, class: []const u8) bool {
        var tokens = std.mem.tokenizeAny(u8, self.get("class") orelse return false, " \t\r\n");
        while (tokens.next()) |token| if (std.mem.eql(u8, token, class)) return true;
        return false;
    }
};

const Declaration = struct { name: []const u8, value: []const u8, important: bool };
const Rule = struct {
    tag: ?[]const u8,
    id: ?[]const u8,
    classes: []const []const u8,
    specificity: u32,
    order: u32,
    declarations: []const Declaration,

    fn matches(self: Rule, node: *const Node) bool {
        if (self.tag) |tag| if (!std.mem.eql(u8, tag, node.name)) return false;
        if (self.id) |id| if (!std.mem.eql(u8, id, node.get("id") orelse return false)) return false;
        for (self.classes) |class| if (!node.hasClass(class)) return false;
        return true;
    }
};

pub const Align = struct {
    x: f64 = 0.5,
    y: f64 = 0.5,
    none: bool = false,
    slice: bool = false,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,
    ids: std.StringHashMapUnmanaged(*Node) = .empty,
    rules: []Rule = &.{},
    width: ?f64 = null,
    height: ?f64 = null,
    view_box: ?[4]f64 = null,
    aspect: Align = .{},

    pub fn parse(gpa: std.mem.Allocator, data: []const u8) !*Document {
        const self = try gpa.create(Document);
        self.* = .{ .arena = .init(gpa), .root = undefined };
        errdefer self.deinit();
        const a = self.arena.allocator();
        self.root = try parseXml(a, data);
        if (!std.mem.eql(u8, self.root.name, "svg")) return error.InvalidSvg;
        var rules: std.ArrayList(Rule) = .empty;
        try self.index(a, self.root, &rules, 0);
        std.mem.sort(Rule, rules.items, {}, struct {
            fn less(_: void, l: Rule, r: Rule) bool {
                return if (l.specificity != r.specificity) l.specificity < r.specificity else l.order < r.order;
            }
        }.less);
        self.rules = rules.items;
        self.width = absoluteLength(self.root.get("width"));
        self.height = absoluteLength(self.root.get("height"));
        if (self.root.get("viewBox")) |value| {
            var numbers: [4]f64 = undefined;
            var scanner: Scanner = .{ .text = value };
            for (&numbers) |*number| number.* = scanner.number() orelse break;
            if (scanner.failed == false and numbers[2] > 0 and numbers[3] > 0) self.view_box = numbers;
        }
        self.aspect = parseAspect(self.root.get("preserveAspectRatio"));
        return self;
    }

    pub fn deinit(self: *Document) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn index(self: *Document, a: std.mem.Allocator, node: *Node, rules: *std.ArrayList(Rule), depth: u32) !void {
        if (depth > 256) return error.InvalidSvg;
        if (node.get("id")) |id| {
            const entry = try self.ids.getOrPut(a, id);
            if (!entry.found_existing) entry.value_ptr.* = node;
        }
        if (std.mem.eql(u8, node.name, "style")) try parseCss(a, node.text, rules);
        for (node.children) |child| try self.index(a, child, rules, depth + 1);
    }

    /// The intrinsic size in pixels: absolute width and height, else the viewBox size.
    pub fn size(self: *const Document) ?[2]f64 {
        if (self.width != null and self.height != null) return .{ self.width.?, self.height.? };
        if (self.view_box) |box| return .{ box[2], box[3] };
        return null;
    }

    /// Draws the document scaled to fill `target`, keeping its aspect ratio.
    pub fn render(self: *const Document, gpa: std.mem.Allocator, target: vec.Target, options: Options) !void {
        const natural = self.size() orelse return error.InvalidSvg;
        const w: f64 = @floatFromInt(target.width);
        const h: f64 = @floatFromInt(target.height);
        const base = if (self.view_box) |box|
            viewportTransform(box, .{ 0, 0, w, h }, self.aspect)
        else
            viewportTransform(.{ 0, 0, natural[0], natural[1] }, .{ 0, 0, w, h }, .{});
        var renderer: Renderer = .{
            .doc = self,
            .gpa = gpa,
            .width = target.width,
            .height = target.height,
            .symbolic = options.symbolic,
            .viewport = if (self.view_box) |box| .{ box[2], box[3] } else natural,
        };
        defer renderer.boxes.deinit(gpa);
        if (options.opacity >= 1) return renderer.element(target, self.root, base, .{}, 0);
        if (options.opacity <= 0) return;
        const layer = try vec.Target.init(gpa, target.width, target.height);
        defer layer.deinit(gpa);
        try renderer.element(layer, self.root, base, .{}, 0);
        vec.composite(target, layer, @floatCast(options.opacity), null);
    }
};

fn viewportTransform(box: [4]f64, viewport: [4]f64, aspect: Align) vec.Transform {
    var sx = viewport[2] / box[2];
    var sy = viewport[3] / box[3];
    if (!aspect.none) {
        const s = if (aspect.slice) @max(sx, sy) else @min(sx, sy);
        sx = s;
        sy = s;
    }
    const tx = viewport[0] + (viewport[2] - box[2] * sx) * (if (aspect.none) 0 else aspect.x) - box[0] * sx;
    const ty = viewport[1] + (viewport[3] - box[3] * sy) * (if (aspect.none) 0 else aspect.y) - box[1] * sy;
    return .{ .a = sx, .d = sy, .e = tx, .f = ty };
}

fn parseAspect(value: ?[]const u8) Align {
    var result: Align = .{};
    var tokens = std.mem.tokenizeAny(u8, value orelse return result, " \t\r\n,");
    var first = tokens.next() orelse return result;
    if (std.mem.eql(u8, first, "defer")) first = tokens.next() orelse return result;
    if (std.mem.eql(u8, first, "none")) {
        result.none = true;
    } else if (first.len == 8 and first[0] == 'x' and first[4] == 'Y') {
        const position = struct {
            fn f(text: []const u8) f64 {
                return if (std.mem.eql(u8, text, "Min")) 0 else if (std.mem.eql(u8, text, "Max")) 1 else 0.5;
            }
        }.f;
        result.x = position(first[1..4]);
        result.y = position(first[5..8]);
    }
    if (tokens.next()) |mode| result.slice = std.mem.eql(u8, mode, "slice");
    return result;
}

// ---------------------------------------------------------------- XML

const entities = std.StaticStringMap([]const u8).initComptime(.{
    .{ "lt", "<" }, .{ "gt", ">" }, .{ "amp", "&" }, .{ "quot", "\"" }, .{ "apos", "'" },
});

fn unescape(a: std.mem.Allocator, text: []const u8, custom: *const std.StringHashMapUnmanaged([]const u8)) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '&') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '&') {
            try out.append(a, text[i]);
            i += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, text, i, ';') orelse {
            try out.appendSlice(a, text[i..]);
            break;
        };
        const name = text[i + 1 .. end];
        if (name.len > 1 and name[0] == '#') {
            const code = if (name[1] == 'x' or name[1] == 'X') std.fmt.parseInt(u21, name[2..], 16) catch null else std.fmt.parseInt(u21, name[1..], 10) catch null;
            var buffer: [4]u8 = undefined;
            if (code) |value| if (std.unicode.utf8Encode(value, &buffer)) |n| {
                try out.appendSlice(a, buffer[0..n]);
                i = end + 1;
                continue;
            } else |_| {};
        } else if (entities.get(name) orelse custom.get(name)) |value| {
            try out.appendSlice(a, value);
            i = end + 1;
            continue;
        }
        try out.appendSlice(a, text[i .. end + 1]);
        i = end + 1;
    }
    return out.items;
}

fn localName(name: []const u8) []const u8 {
    // SVG elements are sometimes written with a namespace prefix ("svg:path").
    if (std.mem.startsWith(u8, name, "svg:")) return name[4..];
    return name;
}

fn isNameChar(c: u8) bool {
    return !std.ascii.isWhitespace(c) and c != '=' and c != '>' and c != '/' and c != '<' and c != '"' and c != '\'';
}

fn parseXml(a: std.mem.Allocator, data: []const u8) !*Node {
    var custom: std.StringHashMapUnmanaged([]const u8) = .empty;
    const Building = struct { node: *Node, children: std.ArrayList(*Node) = .empty, text: std.ArrayList(u8) = .empty };
    var stack: std.ArrayList(Building) = .empty;
    var root: ?*Node = null;
    var i: usize = 0;
    if (std.mem.startsWith(u8, data, "\xef\xbb\xbf")) i = 3;
    while (i < data.len) {
        if (data[i] != '<') {
            const end = std.mem.indexOfScalarPos(u8, data, i, '<') orelse data.len;
            if (stack.items.len > 0) try stack.items[stack.items.len - 1].text.appendSlice(a, try unescape(a, data[i..end], &custom));
            i = end;
            continue;
        }
        const rest = data[i..];
        if (std.mem.startsWith(u8, rest, "<!--")) {
            i = (std.mem.indexOfPos(u8, data, i + 4, "-->") orelse return error.InvalidSvg) + 3;
        } else if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
            const end = std.mem.indexOfPos(u8, data, i + 9, "]]>") orelse return error.InvalidSvg;
            if (stack.items.len > 0) try stack.items[stack.items.len - 1].text.appendSlice(a, data[i + 9 .. end]);
            i = end + 3;
        } else if (std.mem.startsWith(u8, rest, "<?")) {
            i = (std.mem.indexOfPos(u8, data, i + 2, "?>") orelse return error.InvalidSvg) + 2;
        } else if (std.mem.startsWith(u8, rest, "<!")) {
            // DOCTYPE, possibly with an internal subset declaring entities.
            var j = i + 2;
            var depth: u32 = 0;
            while (j < data.len) : (j += 1) switch (data[j]) {
                '[' => depth += 1,
                ']' => depth -|= 1,
                '>' => if (depth == 0) break,
                '<' => if (std.mem.startsWith(u8, data[j..], "<!ENTITY")) {
                    var k = j + 8;
                    while (k < data.len and std.ascii.isWhitespace(data[k])) k += 1;
                    const name_start = k;
                    while (k < data.len and isNameChar(data[k])) k += 1;
                    const name = data[name_start..k];
                    while (k < data.len and std.ascii.isWhitespace(data[k])) k += 1;
                    if (k < data.len and (data[k] == '"' or data[k] == '\'')) {
                        const quote = data[k];
                        const end = std.mem.indexOfScalarPos(u8, data, k + 1, quote) orelse return error.InvalidSvg;
                        try custom.put(a, name, data[k + 1 .. end]);
                        k = end;
                    }
                    j = (std.mem.indexOfScalarPos(u8, data, k, '>') orelse return error.InvalidSvg);
                } else if (std.mem.startsWith(u8, data[j..], "<!--")) {
                    j = (std.mem.indexOfPos(u8, data, j + 4, "-->") orelse return error.InvalidSvg) + 2;
                },
                else => {},
            };
            i = j + 1;
        } else if (std.mem.startsWith(u8, rest, "</")) {
            const end = std.mem.indexOfScalarPos(u8, data, i, '>') orelse return error.InvalidSvg;
            var building = stack.pop() orelse return error.InvalidSvg;
            if (!std.mem.eql(u8, localName(std.mem.trim(u8, data[i + 2 .. end], " \t\r\n")), building.node.name)) return error.InvalidSvg;
            building.node.children = building.children.items;
            building.node.text = building.text.items;
            if (stack.items.len == 0) root = building.node;
            i = end + 1;
        } else {
            var j = i + 1;
            while (j < data.len and isNameChar(data[j])) j += 1;
            const node = try a.create(Node);
            node.* = .{ .name = localName(data[i + 1 .. j]) };
            var attributes: std.ArrayList(Attribute) = .empty;
            var closed = false;
            while (true) {
                while (j < data.len and std.ascii.isWhitespace(data[j])) j += 1;
                if (j >= data.len) return error.InvalidSvg;
                if (data[j] == '>') {
                    j += 1;
                    break;
                }
                if (data[j] == '/') {
                    if (j + 1 >= data.len or data[j + 1] != '>') return error.InvalidSvg;
                    closed = true;
                    j += 2;
                    break;
                }
                const name_start = j;
                while (j < data.len and isNameChar(data[j])) j += 1;
                const name = data[name_start..j];
                if (name.len == 0) return error.InvalidSvg;
                while (j < data.len and std.ascii.isWhitespace(data[j])) j += 1;
                if (j >= data.len or data[j] != '=') return error.InvalidSvg;
                j += 1;
                while (j < data.len and std.ascii.isWhitespace(data[j])) j += 1;
                if (j >= data.len or (data[j] != '"' and data[j] != '\'')) return error.InvalidSvg;
                const quote = data[j];
                const end = std.mem.indexOfScalarPos(u8, data, j + 1, quote) orelse return error.InvalidSvg;
                try attributes.append(a, .{ .name = name, .value = try unescape(a, data[j + 1 .. end], &custom) });
                j = end + 1;
            }
            node.attributes = attributes.items;
            if (stack.items.len > 0) {
                try stack.items[stack.items.len - 1].children.append(a, node);
            } else if (root != null) {
                return error.InvalidSvg;
            }
            if (closed) {
                if (stack.items.len == 0) root = node;
            } else {
                if (stack.items.len > 256) return error.InvalidSvg;
                try stack.append(a, .{ .node = node });
            }
            i = j;
        }
    }
    if (stack.items.len != 0) return error.InvalidSvg;
    return root orelse error.InvalidSvg;
}

// ---------------------------------------------------------------- CSS

fn parseDeclarations(a: std.mem.Allocator, text: []const u8) ![]Declaration {
    var out: std.ArrayList(Declaration) = .empty;
    var parts = std.mem.splitScalar(u8, text, ';');
    while (parts.next()) |part| {
        const colon = std.mem.indexOfScalar(u8, part, ':') orelse continue;
        const name = std.mem.trim(u8, part[0..colon], " \t\r\n");
        var value = std.mem.trim(u8, part[colon + 1 ..], " \t\r\n");
        var important = false;
        if (std.mem.lastIndexOfScalar(u8, value, '!')) |bang| {
            if (std.mem.eql(u8, std.mem.trim(u8, value[bang + 1 ..], " \t\r\n"), "important")) {
                important = true;
                value = std.mem.trim(u8, value[0..bang], " \t\r\n");
            }
        }
        if (name.len > 0) try out.append(a, .{ .name = name, .value = value, .important = important });
    }
    return out.items;
}

fn stripComments(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, "/*") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "/*")) |start| {
        try out.appendSlice(a, text[i..start]);
        i = if (std.mem.indexOfPos(u8, text, start + 2, "*/")) |end| end + 2 else text.len;
    }
    try out.appendSlice(a, text[@min(i, text.len)..]);
    return out.items;
}

fn parseCss(a: std.mem.Allocator, source: []const u8, rules: *std.ArrayList(Rule)) !void {
    const text = try stripComments(a, source);
    var i: usize = 0;
    while (i < text.len) {
        const open = std.mem.indexOfScalarPos(u8, text, i, '{') orelse break;
        const prelude = std.mem.trim(u8, text[i..open], " \t\r\n");
        // Find the matching close brace; at-rules may nest blocks.
        var depth: u32 = 1;
        var j = open + 1;
        while (j < text.len and depth > 0) : (j += 1) switch (text[j]) {
            '{' => depth += 1,
            '}' => depth -= 1,
            else => {},
        };
        const body = text[open + 1 .. if (depth == 0) j - 1 else text.len];
        i = j;
        if (prelude.len == 0 or prelude[0] == '@') continue;
        const declarations = try parseDeclarations(a, body);
        var selectors = std.mem.splitScalar(u8, prelude, ',');
        while (selectors.next()) |raw| {
            const selector = std.mem.trim(u8, raw, " \t\r\n");
            if (selector.len == 0) continue;
            // Only compound selectors: type, *, .class and #id without combinators.
            if (std.mem.indexOfAny(u8, selector, " \t\r\n>+~:[") != null) continue;
            var rule: Rule = .{ .tag = null, .id = null, .classes = &.{}, .specificity = 0, .order = @intCast(rules.items.len), .declarations = declarations };
            var classes: std.ArrayList([]const u8) = .empty;
            var k: usize = 0;
            while (k < selector.len) {
                const kind = selector[k];
                const start = if (kind == '.' or kind == '#') k + 1 else k;
                var end = start;
                while (end < selector.len and selector[end] != '.' and selector[end] != '#') end += 1;
                const name = selector[start..end];
                switch (kind) {
                    '.' => {
                        try classes.append(a, name);
                        rule.specificity += 1 << 8;
                    },
                    '#' => {
                        rule.id = name;
                        rule.specificity += 1 << 16;
                    },
                    else => if (!std.mem.eql(u8, name, "*")) {
                        rule.tag = name;
                        rule.specificity += 1;
                    },
                }
                k = if (end == k) end + 1 else end;
            }
            rule.classes = classes.items;
            try rules.append(a, rule);
        }
    }
}

// ---------------------------------------------------------------- Values

const Scanner = struct {
    text: []const u8,
    i: usize = 0,
    failed: bool = false,

    fn skip(self: *Scanner) void {
        while (self.i < self.text.len and (std.ascii.isWhitespace(self.text[self.i]) or self.text[self.i] == ',')) self.i += 1;
    }
    fn done(self: *Scanner) bool {
        self.skip();
        return self.i >= self.text.len;
    }
    fn peek(self: *Scanner) ?u8 {
        self.skip();
        return if (self.i < self.text.len) self.text[self.i] else null;
    }
    /// SVG number grammar, so that "1.5.5" and "1-2" split into two numbers.
    fn number(self: *Scanner) ?f64 {
        self.skip();
        const start = self.i;
        var j = self.i;
        const t = self.text;
        if (j < t.len and (t[j] == '+' or t[j] == '-')) j += 1;
        var digits = false;
        while (j < t.len and std.ascii.isDigit(t[j])) : (j += 1) digits = true;
        if (j < t.len and t[j] == '.') {
            j += 1;
            while (j < t.len and std.ascii.isDigit(t[j])) : (j += 1) digits = true;
        }
        if (!digits) {
            self.failed = true;
            return null;
        }
        if (j < t.len and (t[j] == 'e' or t[j] == 'E')) {
            var k = j + 1;
            if (k < t.len and (t[k] == '+' or t[k] == '-')) k += 1;
            if (k < t.len and std.ascii.isDigit(t[k])) {
                while (k < t.len and std.ascii.isDigit(t[k])) k += 1;
                j = k;
            }
        }
        self.i = j;
        return std.fmt.parseFloat(f64, t[start..j]) catch {
            self.failed = true;
            return null;
        };
    }
    fn flag(self: *Scanner) ?bool {
        self.skip();
        if (self.i >= self.text.len) return null;
        const c = self.text[self.i];
        if (c != '0' and c != '1') {
            self.failed = true;
            return null;
        }
        self.i += 1;
        return c == '1';
    }
};

const Length = struct { value: f64, percent: bool = false };

fn parseLength(text: ?[]const u8) ?Length {
    const value = std.mem.trim(u8, text orelse return null, " \t\r\n");
    var scanner: Scanner = .{ .text = value };
    const number = scanner.number() orelse return null;
    const unit = std.mem.trim(u8, value[scanner.i..], " \t\r\n");
    const factor: f64 = if (unit.len == 0 or std.mem.eql(u8, unit, "px"))
        1
    else if (std.mem.eql(u8, unit, "%"))
        return .{ .value = number, .percent = true }
    else if (std.mem.eql(u8, unit, "pt"))
        4.0 / 3.0
    else if (std.mem.eql(u8, unit, "pc"))
        16
    else if (std.mem.eql(u8, unit, "mm"))
        96.0 / 25.4
    else if (std.mem.eql(u8, unit, "cm"))
        96.0 / 2.54
    else if (std.mem.eql(u8, unit, "in"))
        96
    else if (std.mem.eql(u8, unit, "em") or std.mem.eql(u8, unit, "rem"))
        16
    else if (std.mem.eql(u8, unit, "ex"))
        8
    else
        return null;
    return .{ .value = number * factor };
}

fn absoluteLength(text: ?[]const u8) ?f64 {
    const length = parseLength(text) orelse return null;
    if (length.percent or !(length.value > 0)) return null;
    return length.value;
}

fn parseTransform(text: ?[]const u8) vec.Transform {
    var result: vec.Transform = .identity;
    const value = text orelse return result;
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and (std.ascii.isWhitespace(value[i]) or value[i] == ',')) i += 1;
        const name_start = i;
        while (i < value.len and std.ascii.isAlphabetic(value[i])) i += 1;
        const name = value[name_start..i];
        if (name.len == 0) break;
        const open = std.mem.indexOfScalarPos(u8, value, i, '(') orelse break;
        const close = std.mem.indexOfScalarPos(u8, value, open, ')') orelse break;
        var scanner: Scanner = .{ .text = value[open + 1 .. close] };
        var args: [6]f64 = @splat(0);
        var count: usize = 0;
        while (count < 6 and !scanner.done()) : (count += 1) args[count] = scanner.number() orelse return .identity;
        i = close + 1;
        const t: vec.Transform = if (std.mem.eql(u8, name, "matrix") and count == 6)
            .{ .a = args[0], .b = args[1], .c = args[2], .d = args[3], .e = args[4], .f = args[5] }
        else if (std.mem.eql(u8, name, "translate") and count >= 1)
            .translate(args[0], if (count >= 2) args[1] else 0)
        else if (std.mem.eql(u8, name, "scale") and count >= 1)
            .scale(args[0], if (count >= 2) args[1] else args[0])
        else if (std.mem.eql(u8, name, "rotate") and count >= 1) blk: {
            const r = vec.Transform.rotate(std.math.degreesToRadians(args[0]));
            if (count < 3) break :blk r;
            break :blk vec.Transform.translate(args[1], args[2]).mul(r).mul(.translate(-args[1], -args[2]));
        } else if (std.mem.eql(u8, name, "skewX") and count >= 1)
            .{ .c = @tan(std.math.degreesToRadians(args[0])) }
        else if (std.mem.eql(u8, name, "skewY") and count >= 1)
            .{ .b = @tan(std.math.degreesToRadians(args[0])) }
        else
            return .identity;
        result = result.mul(t);
    }
    return result;
}

const named_colors = std.StaticStringMap(u32).initComptime(.{
    .{ "aliceblue", 0xf0f8ff },            .{ "antiquewhite", 0xfaebd7 },      .{ "aqua", 0x00ffff },
    .{ "aquamarine", 0x7fffd4 },           .{ "azure", 0xf0ffff },             .{ "beige", 0xf5f5dc },
    .{ "bisque", 0xffe4c4 },               .{ "black", 0x000000 },             .{ "blanchedalmond", 0xffebcd },
    .{ "blue", 0x0000ff },                 .{ "blueviolet", 0x8a2be2 },        .{ "brown", 0xa52a2a },
    .{ "burlywood", 0xdeb887 },            .{ "cadetblue", 0x5f9ea0 },         .{ "chartreuse", 0x7fff00 },
    .{ "chocolate", 0xd2691e },            .{ "coral", 0xff7f50 },             .{ "cornflowerblue", 0x6495ed },
    .{ "cornsilk", 0xfff8dc },             .{ "crimson", 0xdc143c },           .{ "cyan", 0x00ffff },
    .{ "darkblue", 0x00008b },             .{ "darkcyan", 0x008b8b },          .{ "darkgoldenrod", 0xb8860b },
    .{ "darkgray", 0xa9a9a9 },             .{ "darkgreen", 0x006400 },         .{ "darkgrey", 0xa9a9a9 },
    .{ "darkkhaki", 0xbdb76b },            .{ "darkmagenta", 0x8b008b },       .{ "darkolivegreen", 0x556b2f },
    .{ "darkorange", 0xff8c00 },           .{ "darkorchid", 0x9932cc },        .{ "darkred", 0x8b0000 },
    .{ "darksalmon", 0xe9967a },           .{ "darkseagreen", 0x8fbc8f },      .{ "darkslateblue", 0x483d8b },
    .{ "darkslategray", 0x2f4f4f },        .{ "darkslategrey", 0x2f4f4f },     .{ "darkturquoise", 0x00ced1 },
    .{ "darkviolet", 0x9400d3 },           .{ "deeppink", 0xff1493 },          .{ "deepskyblue", 0x00bfff },
    .{ "dimgray", 0x696969 },              .{ "dimgrey", 0x696969 },           .{ "dodgerblue", 0x1e90ff },
    .{ "firebrick", 0xb22222 },            .{ "floralwhite", 0xfffaf0 },       .{ "forestgreen", 0x228b22 },
    .{ "fuchsia", 0xff00ff },              .{ "gainsboro", 0xdcdcdc },         .{ "ghostwhite", 0xf8f8ff },
    .{ "gold", 0xffd700 },                 .{ "goldenrod", 0xdaa520 },         .{ "gray", 0x808080 },
    .{ "green", 0x008000 },                .{ "greenyellow", 0xadff2f },       .{ "grey", 0x808080 },
    .{ "honeydew", 0xf0fff0 },             .{ "hotpink", 0xff69b4 },           .{ "indianred", 0xcd5c5c },
    .{ "indigo", 0x4b0082 },               .{ "ivory", 0xfffff0 },             .{ "khaki", 0xf0e68c },
    .{ "lavender", 0xe6e6fa },             .{ "lavenderblush", 0xfff0f5 },     .{ "lawngreen", 0x7cfc00 },
    .{ "lemonchiffon", 0xfffacd },         .{ "lightblue", 0xadd8e6 },         .{ "lightcoral", 0xf08080 },
    .{ "lightcyan", 0xe0ffff },            .{ "lightgoldenrodyellow", 0xfafad2 }, .{ "lightgray", 0xd3d3d3 },
    .{ "lightgreen", 0x90ee90 },           .{ "lightgrey", 0xd3d3d3 },         .{ "lightpink", 0xffb6c1 },
    .{ "lightsalmon", 0xffa07a },          .{ "lightseagreen", 0x20b2aa },     .{ "lightskyblue", 0x87cefa },
    .{ "lightslategray", 0x778899 },       .{ "lightslategrey", 0x778899 },    .{ "lightsteelblue", 0xb0c4de },
    .{ "lightyellow", 0xffffe0 },          .{ "lime", 0x00ff00 },              .{ "limegreen", 0x32cd32 },
    .{ "linen", 0xfaf0e6 },                .{ "magenta", 0xff00ff },           .{ "maroon", 0x800000 },
    .{ "mediumaquamarine", 0x66cdaa },     .{ "mediumblue", 0x0000cd },        .{ "mediumorchid", 0xba55d3 },
    .{ "mediumpurple", 0x9370db },         .{ "mediumseagreen", 0x3cb371 },    .{ "mediumslateblue", 0x7b68ee },
    .{ "mediumspringgreen", 0x00fa9a },    .{ "mediumturquoise", 0x48d1cc },   .{ "mediumvioletred", 0xc71585 },
    .{ "midnightblue", 0x191970 },         .{ "mintcream", 0xf5fffa },         .{ "mistyrose", 0xffe4e1 },
    .{ "moccasin", 0xffe4b5 },             .{ "navajowhite", 0xffdead },       .{ "navy", 0x000080 },
    .{ "oldlace", 0xfdf5e6 },              .{ "olive", 0x808000 },             .{ "olivedrab", 0x6b8e23 },
    .{ "orange", 0xffa500 },               .{ "orangered", 0xff4500 },         .{ "orchid", 0xda70d6 },
    .{ "palegoldenrod", 0xeee8aa },        .{ "palegreen", 0x98fb98 },         .{ "paleturquoise", 0xafeeee },
    .{ "palevioletred", 0xdb7093 },        .{ "papayawhip", 0xffefd5 },        .{ "peachpuff", 0xffdab9 },
    .{ "peru", 0xcd853f },                 .{ "pink", 0xffc0cb },              .{ "plum", 0xdda0dd },
    .{ "powderblue", 0xb0e0e6 },           .{ "purple", 0x800080 },            .{ "rebeccapurple", 0x663399 },
    .{ "red", 0xff0000 },                  .{ "rosybrown", 0xbc8f8f },         .{ "royalblue", 0x4169e1 },
    .{ "saddlebrown", 0x8b4513 },          .{ "salmon", 0xfa8072 },            .{ "sandybrown", 0xf4a460 },
    .{ "seagreen", 0x2e8b57 },             .{ "seashell", 0xfff5ee },          .{ "sienna", 0xa0522d },
    .{ "silver", 0xc0c0c0 },               .{ "skyblue", 0x87ceeb },           .{ "slateblue", 0x6a5acd },
    .{ "slategray", 0x708090 },            .{ "slategrey", 0x708090 },         .{ "snow", 0xfffafa },
    .{ "springgreen", 0x00ff7f },          .{ "steelblue", 0x4682b4 },         .{ "tan", 0xd2b48c },
    .{ "teal", 0x008080 },                 .{ "thistle", 0xd8bfd8 },           .{ "tomato", 0xff6347 },
    .{ "turquoise", 0x40e0d0 },            .{ "violet", 0xee82ee },            .{ "wheat", 0xf5deb3 },
    .{ "white", 0xffffff },                .{ "whitesmoke", 0xf5f5f5 },        .{ "yellow", 0xffff00 },
    .{ "yellowgreen", 0x9acd32 },
});

fn hexDigit(c: u8) ?u32 {
    return std.fmt.charToDigit(c, 16) catch null;
}

fn parseColor(text: []const u8) ?Color {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (value.len == 0) return null;
    if (value[0] == '#') {
        const hex = value[1..];
        var digits: [8]u32 = undefined;
        for (hex, 0..) |c, i| {
            if (i >= 8) return null;
            digits[i] = hexDigit(c) orelse return null;
        }
        return switch (hex.len) {
            3, 4 => .{
                .rgb = (digits[0] * 17) << 16 | (digits[1] * 17) << 8 | digits[2] * 17,
                .alpha = if (hex.len == 4) @as(f64, @floatFromInt(digits[3] * 17)) / 255 else 1,
            },
            6, 8 => .{
                .rgb = (digits[0] << 20) | (digits[1] << 16) | (digits[2] << 12) | (digits[3] << 8) | (digits[4] << 4) | digits[5],
                .alpha = if (hex.len == 8) @as(f64, @floatFromInt(digits[6] * 16 + digits[7])) / 255 else 1,
            },
            else => null,
        };
    }
    var lower: [32]u8 = undefined;
    if (value.len <= lower.len) {
        const name = std.ascii.lowerString(&lower, value);
        if (named_colors.get(name)) |rgb| return .{ .rgb = rgb };
        if (std.mem.eql(u8, name, "transparent")) return .{ .rgb = 0, .alpha = 0 };
    }
    if (std.mem.startsWith(u8, value, "rgb")) {
        const open = std.mem.indexOfScalar(u8, value, '(') orelse return null;
        const close = std.mem.lastIndexOfScalar(u8, value, ')') orelse return null;
        var parts = std.mem.tokenizeAny(u8, value[open + 1 .. close], " \t\r\n,/");
        var channels: [4]f64 = .{ 0, 0, 0, 1 };
        var count: usize = 0;
        while (parts.next()) |part| : (count += 1) {
            if (count >= 4) return null;
            const percent = std.mem.endsWith(u8, part, "%");
            const number = std.fmt.parseFloat(f64, if (percent) part[0 .. part.len - 1] else part) catch return null;
            channels[count] = if (count == 3)
                (if (percent) number / 100 else number)
            else if (percent) number * 2.55 else number;
        }
        if (count < 3) return null;
        var rgb: u32 = 0;
        for (channels[0..3]) |channel| rgb = (rgb << 8) | @as(u32, @intFromFloat(@round(std.math.clamp(channel, 0, 255))));
        return .{ .rgb = rgb, .alpha = std.math.clamp(channels[3], 0, 1) };
    }
    return null;
}

const Solid = union(enum) { none, current, color: Color };
const Paint = struct { solid: Solid, url: ?[]const u8 = null };

fn parseSolid(text: []const u8) ?Solid {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "currentColor") or std.mem.eql(u8, value, "currentcolor")) return .current;
    return .{ .color = parseColor(value) orelse return null };
}

fn parsePaint(text: []const u8) ?Paint {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, value, "url(")) {
        const close = std.mem.indexOfScalar(u8, value, ')') orelse return null;
        const reference = std.mem.trim(u8, value[4..close], " \t\r\n\"'");
        if (reference.len < 2 or reference[0] != '#') return null;
        const fallback = std.mem.trim(u8, value[close + 1 ..], " \t\r\n");
        return .{ .url = reference[1..], .solid = if (fallback.len > 0) parseSolid(fallback) orelse .none else .none };
    }
    return .{ .solid = parseSolid(value) orelse return null };
}

fn parseUrl(text: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, value, "url(")) return null;
    const close = std.mem.indexOfScalar(u8, value, ')') orelse return null;
    const reference = std.mem.trim(u8, value[4..close], " \t\r\n\"'");
    if (reference.len < 2 or reference[0] != '#') return null;
    return reference[1..];
}

fn parseNumber(text: []const u8) ?f64 {
    var scanner: Scanner = .{ .text = text };
    const value = scanner.number() orelse return null;
    if (!scanner.done()) {
        if (std.mem.eql(u8, std.mem.trim(u8, text[scanner.i..], " \t\r\n"), "%")) return value / 100;
        return null;
    }
    return value;
}

fn parseOpacity(text: []const u8) ?f64 {
    return std.math.clamp(parseNumber(text) orelse return null, 0, 1);
}

// ---------------------------------------------------------------- Style

const Style = struct {
    fill: Paint = .{ .solid = .{ .color = .black } },
    fill_opacity: f64 = 1,
    fill_rule: vec.FillRule = .nonzero,
    clip_rule: vec.FillRule = .nonzero,
    stroke: Paint = .{ .solid = .none },
    stroke_width: f64 = 1,
    stroke_opacity: f64 = 1,
    cap: vec.Cap = .butt,
    join: vec.Join = .miter,
    miter_limit: f64 = 4,
    dashes: []const f64 = &.{},
    dash_offset: f64 = 0,
    color: Color = .black,
    visible: bool = true,
    // Not inherited.
    display: bool = true,
    opacity: f64 = 1,
    clip_path: ?[]const u8 = null,
    mask: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    stop_color: Solid = .{ .color = .black },
    stop_opacity: f64 = 1,

    fn inherit(parent: Style) Style {
        var style = parent;
        style.display = true;
        style.opacity = 1;
        style.clip_path = null;
        style.mask = null;
        style.filter = null;
        style.stop_color = .{ .color = .black };
        style.stop_opacity = 1;
        return style;
    }

    fn apply(self: *Style, a: std.mem.Allocator, parent: Style, name: []const u8, raw: []const u8) void {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        const eql = std.mem.eql;
        if (eql(u8, value, "inherit")) {
            inline for (.{ "fill", "fill_opacity", "fill_rule", "clip_rule", "stroke", "stroke_width", "stroke_opacity", "cap", "join", "miter_limit", "dashes", "dash_offset", "color", "visible", "display", "opacity", "clip_path", "mask", "filter", "stop_color", "stop_opacity" }) |field| {
                var css_name: [field.len]u8 = field.*;
                std.mem.replaceScalar(u8, &css_name, '_', '-');
                const alias = if (eql(u8, field, "cap")) "stroke-linecap" else if (eql(u8, field, "join")) "stroke-linejoin" else if (eql(u8, field, "miter_limit")) "stroke-miterlimit" else if (eql(u8, field, "dashes")) "stroke-dasharray" else if (eql(u8, field, "dash_offset")) "stroke-dashoffset" else if (eql(u8, field, "visible")) "visibility" else &css_name;
                if (eql(u8, name, alias)) @field(self, field) = @field(parent, field);
            }
            return;
        }
        if (eql(u8, name, "fill")) {
            if (parsePaint(value)) |paint| self.fill = paint;
        } else if (eql(u8, name, "stroke")) {
            if (parsePaint(value)) |paint| self.stroke = paint;
        } else if (eql(u8, name, "fill-opacity")) {
            if (parseOpacity(value)) |number| self.fill_opacity = number;
        } else if (eql(u8, name, "stroke-opacity")) {
            if (parseOpacity(value)) |number| self.stroke_opacity = number;
        } else if (eql(u8, name, "opacity")) {
            if (parseOpacity(value)) |number| self.opacity = number;
        } else if (eql(u8, name, "stop-opacity")) {
            if (parseOpacity(value)) |number| self.stop_opacity = number;
        } else if (eql(u8, name, "stop-color")) {
            if (parseSolid(value)) |solid| self.stop_color = solid;
        } else if (eql(u8, name, "color")) {
            if (parseColor(value)) |color| self.color = color;
        } else if (eql(u8, name, "fill-rule")) {
            self.fill_rule = if (eql(u8, value, "evenodd")) .evenodd else .nonzero;
        } else if (eql(u8, name, "clip-rule")) {
            self.clip_rule = if (eql(u8, value, "evenodd")) .evenodd else .nonzero;
        } else if (eql(u8, name, "stroke-width")) {
            if (parseLength(value)) |length| if (!length.percent and length.value >= 0) {
                self.stroke_width = length.value;
            };
        } else if (eql(u8, name, "stroke-linecap")) {
            self.cap = if (eql(u8, value, "round")) .round else if (eql(u8, value, "square")) .square else .butt;
        } else if (eql(u8, name, "stroke-linejoin")) {
            self.join = if (eql(u8, value, "round")) .round else if (eql(u8, value, "bevel")) .bevel else .miter;
        } else if (eql(u8, name, "stroke-miterlimit")) {
            if (parseNumber(value)) |number| if (number >= 1) {
                self.miter_limit = number;
            };
        } else if (eql(u8, name, "stroke-dasharray")) {
            self.dashes = parseDashes(a, value);
        } else if (eql(u8, name, "stroke-dashoffset")) {
            if (parseLength(value)) |length| if (!length.percent) {
                self.dash_offset = length.value;
            };
        } else if (eql(u8, name, "display")) {
            self.display = !eql(u8, value, "none");
        } else if (eql(u8, name, "visibility")) {
            self.visible = eql(u8, value, "visible");
        } else if (eql(u8, name, "clip-path")) {
            self.clip_path = parseUrl(value);
        } else if (eql(u8, name, "filter")) {
            self.filter = parseUrl(value);
        } else if (eql(u8, name, "mask")) {
            self.mask = parseUrl(value);
        }
    }
};

fn parseDashes(a: std.mem.Allocator, text: []const u8) []const f64 {
    if (std.mem.eql(u8, text, "none")) return &.{};
    var values: std.ArrayList(f64) = .empty;
    var parts = std.mem.tokenizeAny(u8, text, " \t\r\n,");
    while (parts.next()) |part| {
        const length = parseLength(part) orelse return &.{};
        if (length.percent or length.value < 0) return &.{};
        values.append(a, length.value) catch return &.{};
    }
    // An odd number of values repeats to make an even list.
    if (values.items.len % 2 == 1) values.appendSlice(a, values.items) catch return &.{};
    return values.items;
}

// ---------------------------------------------------------------- Rendering

const max_depth = 64;

const Renderer = struct {
    doc: *const Document,
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    symbolic: ?Symbolic,
    viewport: [2]f64,
    pattern_depth: u32 = 0,
    boxes: std.AutoHashMapUnmanaged(*const Node, ?[4]f64) = .empty,

    fn compute(self: *Renderer, a: std.mem.Allocator, node: *const Node, parent: Style) Style {
        var style = Style.inherit(parent);
        for (node.attributes) |attribute| style.apply(a, parent, attribute.name, attribute.value);
        for (self.doc.rules) |rule| if (rule.matches(node)) {
            for (rule.declarations) |declaration| if (!declaration.important) style.apply(a, parent, declaration.name, declaration.value);
        };
        if (node.get("style")) |inline_style| {
            const declarations = parseDeclarations(a, inline_style) catch &.{};
            for (declarations) |declaration| style.apply(a, parent, declaration.name, declaration.value);
        }
        for (self.doc.rules) |rule| if (rule.matches(node)) {
            for (rule.declarations) |declaration| if (declaration.important) style.apply(a, parent, declaration.name, declaration.value);
        };
        if (self.symbolic) |palette| {
            const recolored = std.mem.eql(u8, node.name, "rect") or std.mem.eql(u8, node.name, "circle") or std.mem.eql(u8, node.name, "path");
            if (recolored) {
                const color = if (node.hasClass("success")) palette.success else if (node.hasClass("warning")) palette.warning else if (node.hasClass("error")) palette.@"error" else palette.foreground;
                if (node.hasClass("stroke")) {
                    style.fill = .{ .solid = .none };
                    style.stroke = .{ .solid = .{ .color = color } };
                } else {
                    style.fill = .{ .solid = .{ .color = color } };
                    style.stroke = .{ .solid = .none };
                }
            }
        }
        return style;
    }

    fn length(self: *const Renderer, node: *const Node, name: []const u8, axis: enum { x, y, other }, default: f64) f64 {
        const value = parseLength(node.get(name)) orelse return default;
        if (!value.percent) return value.value;
        const basis = switch (axis) {
            .x => self.viewport[0],
            .y => self.viewport[1],
            .other => @sqrt((self.viewport[0] * self.viewport[0] + self.viewport[1] * self.viewport[1]) / 2),
        };
        return value.value / 100 * basis;
    }

    fn shape(self: *const Renderer, node: *const Node, path: *vec.Path) !bool {
        const a = self.gpa;
        const name = node.name;
        const eql = std.mem.eql;
        if (eql(u8, name, "path")) {
            try parsePathData(a, node.get("d") orelse return true, path);
        } else if (eql(u8, name, "rect")) {
            const w = self.length(node, "width", .x, 0);
            const h = self.length(node, "height", .y, 0);
            if (!(w > 0 and h > 0)) return true;
            var rx = self.length(node, "rx", .x, -1);
            var ry = self.length(node, "ry", .y, -1);
            if (rx < 0) rx = ry;
            if (ry < 0) ry = rx;
            try path.roundedRect(a, self.length(node, "x", .x, 0), self.length(node, "y", .y, 0), w, h, @max(rx, 0), @max(ry, 0));
        } else if (eql(u8, name, "circle")) {
            const r = self.length(node, "r", .other, 0);
            if (r > 0) try path.ellipse(a, .{ .x = self.length(node, "cx", .x, 0), .y = self.length(node, "cy", .y, 0) }, r, r);
        } else if (eql(u8, name, "ellipse")) {
            var rx = self.length(node, "rx", .x, -1);
            var ry = self.length(node, "ry", .y, -1);
            if (rx < 0) rx = ry;
            if (ry < 0) ry = rx;
            if (rx > 0 and ry > 0) try path.ellipse(a, .{ .x = self.length(node, "cx", .x, 0), .y = self.length(node, "cy", .y, 0) }, rx, ry);
        } else if (eql(u8, name, "line")) {
            try path.moveTo(a, .{ .x = self.length(node, "x1", .x, 0), .y = self.length(node, "y1", .y, 0) });
            try path.lineTo(a, .{ .x = self.length(node, "x2", .x, 0), .y = self.length(node, "y2", .y, 0) });
        } else if (eql(u8, name, "polyline") or eql(u8, name, "polygon")) {
            var scanner: Scanner = .{ .text = node.get("points") orelse return true };
            var first = true;
            while (!scanner.done()) {
                const x = scanner.number() orelse break;
                const y = scanner.number() orelse break;
                if (first) try path.moveTo(a, .{ .x = x, .y = y }) else try path.lineTo(a, .{ .x = x, .y = y });
                first = false;
            }
            if (eql(u8, name, "polygon") and !first) try path.close(a);
        } else return false;
        return true;
    }

    fn element(self: *Renderer, target: vec.Target, node: *const Node, ctm: vec.Transform, parent: Style, depth: u32) anyerror!void {
        if (depth > max_depth) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const style = self.compute(a, node, parent);
        if (!style.display or style.opacity <= 0) return;
        const eql = std.mem.eql;
        const name = node.name;
        const skipped = [_][]const u8{ "defs", "clipPath", "mask", "linearGradient", "radialGradient", "pattern", "symbol", "marker", "filter", "style", "title", "desc", "metadata", "text", "font", "script", "foreignObject" };
        for (skipped) |kind| if (eql(u8, name, kind)) return;

        var local = ctm;
        if (depth > 0) local = ctm.mul(parseTransform(node.get("transform")));
        if (eql(u8, name, "svg") and depth > 0) {
            const w = self.length(node, "width", .x, self.viewport[0]);
            const h = self.length(node, "height", .y, self.viewport[1]);
            const x = self.length(node, "x", .x, 0);
            const y = self.length(node, "y", .y, 0);
            local = ctm.mul(.translate(x, y));
            if (node.get("viewBox")) |value| {
                var box: [4]f64 = undefined;
                var scanner: Scanner = .{ .text = value };
                for (&box) |*number| number.* = scanner.number() orelse 0;
                if (box[2] > 0 and box[3] > 0) local = local.mul(viewportTransform(box, .{ 0, 0, w, h }, parseAspect(node.get("preserveAspectRatio"))));
            }
        }
        // Masks and clips are costly; skip elements that cannot reach the output,
        // as librsvg does.
        if ((style.clip_path != null or style.mask != null) and !eql(u8, name, "use") and !self.visible(node, local, style, depth)) return;
        var path: vec.Path = .{};
        defer path.deinit(self.gpa);
        const is_shape = try self.shape(node, &path);
        const is_image = eql(u8, name, "image");
        const is_use = eql(u8, name, "use");
        const fill_visible = style.fill.solid != .none or style.fill.url != null;
        const stroke_visible = (style.stroke.solid != .none or style.stroke.url != null) and style.stroke_width > 0;
        // A single paint operation can carry the group opacity without a layer.
        const filter = if (style.filter) |id| self.doc.ids.get(id) else null;
        const fold = filter == null and style.clip_path == null and style.mask == null and (is_image or (is_shape and !(fill_visible and stroke_visible)));
        const needs_layer = !fold and (style.opacity < 1 or style.clip_path != null or style.mask != null or filter != null);
        var dest = target;
        var layer: ?vec.Target = null;
        defer if (layer) |value| value.deinit(self.gpa);
        if (needs_layer) {
            layer = try vec.Target.init(self.gpa, self.width, self.height);
            dest = layer.?;
        }
        const opacity: f64 = if (fold) style.opacity else 1;

        if (is_shape) {
            if (style.visible) try self.drawShape(dest, node, &path, local, style, opacity);
        } else if (is_image) {
            if (style.visible) try self.drawImage(dest, node, local, opacity);
        } else if (is_use) {
            const id = node.href() orelse return;
            if (id.len < 2 or id[0] != '#') return;
            const referenced = self.doc.ids.get(id[1..]) orelse return;
            const moved = local.mul(.translate(self.length(node, "x", .x, 0), self.length(node, "y", .y, 0)));
            if (eql(u8, referenced.name, "symbol")) {
                var symbol_transform = moved;
                if (referenced.get("viewBox")) |value| {
                    var box: [4]f64 = undefined;
                    var scanner: Scanner = .{ .text = value };
                    for (&box) |*number| number.* = scanner.number() orelse 0;
                    const w = self.length(node, "width", .x, self.viewport[0]);
                    const h = self.length(node, "height", .y, self.viewport[1]);
                    if (box[2] > 0 and box[3] > 0) symbol_transform = moved.mul(viewportTransform(box, .{ 0, 0, w, h }, parseAspect(referenced.get("preserveAspectRatio"))));
                }
                for (referenced.children) |child| try self.element(dest, child, symbol_transform, style, depth + 1);
            } else {
                try self.element(dest, referenced, moved, style, depth + 1);
            }
        } else if (eql(u8, name, "switch")) {
            for (node.children) |child| {
                if (isRenderable(child.name)) {
                    try self.element(dest, child, local, style, depth + 1);
                    break;
                }
            }
        } else {
            // svg, g, a and unknown containers render their children.
            for (node.children) |child| try self.element(dest, child, local, style, depth + 1);
        }

        const value = layer orelse return;
        var mask: ?[]f32 = null;
        defer if (mask) |values| self.gpa.free(values);
        if (style.clip_path != null or style.mask != null) {
            const box = self.bbox(node, depth);
            if (style.clip_path) |id| mask = try self.clipCoverage(id, local, box, depth);
            if (style.mask) |id| if (try self.maskCoverage(id, local, box, depth)) |values| {
                if (mask) |existing| {
                    for (existing, values) |*m, v| m.* *= v;
                    self.gpa.free(values);
                } else mask = values;
            };
        }
        if (filter) |f| applyFilter(f, value);
        vec.composite(target, value, @floatCast(style.opacity), mask);
    }

    fn drawShape(self: *Renderer, dest: vec.Target, node: *const Node, path: *const vec.Path, t: vec.Transform, style: Style, opacity: f64) !void {
        if (path.verbs.items.len == 0) return;
        var box: ?[4]f64 = null;
        if (style.fill.solid != .none or style.fill.url != null) {
            if (style.fill.url != null and box == null) box = self.bbox(node, 0);
            var state: PaintState = .{};
            defer state.deinit(self.gpa);
            if (try self.paint(style.fill, style, box, t, &state)) |resolved| {
                try vec.fillPath(self.gpa, dest, path.*, t, style.fill_rule, resolved.paint, @floatCast(resolved.opacity * style.fill_opacity * opacity));
            }
        }
        if ((style.stroke.solid != .none or style.stroke.url != null) and style.stroke_width > 0) {
            if (style.stroke.url != null and box == null) box = self.bbox(node, 0);
            var state: PaintState = .{};
            defer state.deinit(self.gpa);
            if (try self.paint(style.stroke, style, box, t, &state)) |resolved| {
                try vec.strokePath(self.gpa, dest, path.*, t, .{
                    .width = style.stroke_width,
                    .cap = style.cap,
                    .join = style.join,
                    .miter_limit = style.miter_limit,
                    .dashes = style.dashes,
                    .dash_offset = style.dash_offset,
                }, resolved.paint, @floatCast(resolved.opacity * style.stroke_opacity * opacity));
            }
        }
    }

    const Resolved = struct { paint: vec.Paint, opacity: f64 };

    fn solidPaint(solid: Solid, style: Style) ?Resolved {
        const color = switch (solid) {
            .none => return null,
            .current => style.color,
            .color => |value| value,
        };
        return .{ .paint = .{ .solid = color.premultiplied(1) }, .opacity = 1 };
    }

    fn paint(self: *Renderer, spec: Paint, style: Style, box: ?[4]f64, t: vec.Transform, state: *PaintState) !?Resolved {
        const id = spec.url orelse return solidPaint(spec.solid, style);
        const node = self.doc.ids.get(id) orelse return solidPaint(spec.solid, style);
        if (std.mem.eql(u8, node.name, "pattern")) {
            if (!try state.pattern.init(self, node, style, box, t)) return solidPaint(spec.solid, style);
            return .{ .paint = .{ .shader = .{ .context = &state.pattern, .sample = Pattern.sample } }, .opacity = 1 };
        }
        if (!state.gradient.init(self, node, style, box, t)) return solidPaint(spec.solid, style);
        if (state.gradient.single) |pixel| return .{ .paint = .{ .solid = pixel }, .opacity = 1 };
        return .{ .paint = .{ .shader = .{ .context = &state.gradient, .sample = Gradient.sample } }, .opacity = 1 };
    }

    fn drawImage(self: *Renderer, dest: vec.Target, node: *const Node, t: vec.Transform, opacity: f64) !void {
        const reference = node.href() orelse return;
        const prefix = "data:image/png;base64,";
        if (!std.mem.startsWith(u8, reference, prefix)) return;
        const encoded = reference[prefix.len..];
        const clean = try self.gpa.alloc(u8, encoded.len);
        defer self.gpa.free(clean);
        var n: usize = 0;
        for (encoded) |c| if (!std.ascii.isWhitespace(c)) {
            clean[n] = c;
            n += 1;
        };
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(clean[0..n]) catch return;
        const bytes = try self.gpa.alloc(u8, size);
        defer self.gpa.free(bytes);
        decoder.decode(bytes, clean[0..n]) catch return;
        const image = png.decode(self.gpa, bytes) catch return;
        defer self.gpa.free(image.pixels);
        const iw: f64 = @floatFromInt(image.width);
        const ih: f64 = @floatFromInt(image.height);
        const x = self.length(node, "x", .x, 0);
        const y = self.length(node, "y", .y, 0);
        const w = self.length(node, "width", .x, iw);
        const h = self.length(node, "height", .y, ih);
        if (!(w > 0 and h > 0)) return;
        const placement = t.mul(viewportTransform(.{ 0, 0, iw, ih }, .{ x, y, w, h }, parseAspect(node.get("preserveAspectRatio"))));
        var sampler: ImageShader = .{
            .pixels = std.mem.bytesAsSlice(u32, image.pixels),
            .width = image.width,
            .height = image.height,
            .inverse = placement.invert() orelse return,
        };
        var outline: vec.Path = .{};
        defer outline.deinit(self.gpa);
        try outline.rect(self.gpa, 0, 0, iw, ih);
        try vec.fillPath(self.gpa, dest, outline, placement, .nonzero, .{ .shader = .{ .context = &sampler, .sample = ImageShader.sample } }, @floatCast(opacity));
    }

    /// Whether the element's bounds, padded for strokes, overlap the target.
    fn visible(self: *Renderer, node: *const Node, t: vec.Transform, style: Style, depth: u32) bool {
        const box = self.bbox(node, depth) orelse return true;
        const pad = @max(style.stroke_width, 1) * @max(t.scaleFactor(), 1) + 2;
        var lo: vec.Point = .{ .x = std.math.inf(f64), .y = std.math.inf(f64) };
        var hi: vec.Point = .{ .x = -std.math.inf(f64), .y = -std.math.inf(f64) };
        for ([_][2]f64{ .{ box[0], box[1] }, .{ box[2], box[1] }, .{ box[0], box[3] }, .{ box[2], box[3] } }) |corner| {
            const p = t.apply(.{ .x = corner[0], .y = corner[1] });
            lo = .{ .x = @min(lo.x, p.x), .y = @min(lo.y, p.y) };
            hi = .{ .x = @max(hi.x, p.x), .y = @max(hi.y, p.y) };
        }
        const w: f64 = @floatFromInt(self.width);
        const h: f64 = @floatFromInt(self.height);
        return hi.x + pad > 0 and hi.y + pad > 0 and lo.x - pad < w and lo.y - pad < h;
    }

    /// Bounding box in the element's own user space (after its transform).
    fn bbox(self: *Renderer, node: *const Node, depth: u32) ?[4]f64 {
        if (depth > max_depth) return null;
        // Nested masked groups ask for the same boxes repeatedly; compute each once.
        if (self.boxes.get(node)) |cached| return cached;
        const box = self.computeBbox(node, depth);
        self.boxes.put(self.gpa, node, box) catch {};
        return box;
    }

    fn computeBbox(self: *Renderer, node: *const Node, depth: u32) ?[4]f64 {
        var path: vec.Path = .{};
        defer path.deinit(self.gpa);
        const is_shape = self.shape(node, &path) catch return null;
        if (is_shape) {
            var flat: vec.Flat = .{};
            defer flat.deinit(self.gpa);
            vec.flatten(self.gpa, path, .identity, 0.05, &flat) catch return null;
            var box: ?[4]f64 = null;
            for (flat.points.items) |p| box = extend(box, p);
            return box;
        }
        var box: ?[4]f64 = null;
        for (node.children) |child| {
            const child_box = self.bbox(child, depth + 1) orelse continue;
            const t = parseTransform(child.get("transform"));
            for ([_][2]f64{ .{ child_box[0], child_box[1] }, .{ child_box[2], child_box[1] }, .{ child_box[0], child_box[3] }, .{ child_box[2], child_box[3] } }) |corner| {
                box = extend(box, t.apply(.{ .x = corner[0], .y = corner[1] }));
            }
        }
        return box;
    }

    fn clipCoverage(self: *Renderer, id: []const u8, ctm: vec.Transform, box: ?[4]f64, depth: u32) !?[]f32 {
        const node = self.doc.ids.get(id) orelse return null;
        if (!std.mem.eql(u8, node.name, "clipPath")) return null;
        var t = ctm.mul(parseTransform(node.get("transform")));
        if (std.mem.eql(u8, node.get("clipPathUnits") orelse "", "objectBoundingBox")) {
            const b = box orelse return try self.zeros();
            t = t.mul(.{ .a = b[2] - b[0], .d = b[3] - b[1], .e = b[0], .f = b[1] });
        }
        const coverage = try self.zeros();
        errdefer self.gpa.free(coverage);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        for (node.children) |child| {
            var shape_node = child;
            var child_t = t.mul(parseTransform(child.get("transform")));
            if (std.mem.eql(u8, child.name, "use")) {
                const reference = child.href() orelse continue;
                if (reference.len < 2) continue;
                shape_node = self.doc.ids.get(reference[1..]) orelse continue;
                child_t = child_t.mul(.translate(self.length(child, "x", .x, 0), self.length(child, "y", .y, 0))).mul(parseTransform(shape_node.get("transform")));
            }
            const style = self.compute(arena.allocator(), shape_node, .{});
            if (!style.display or !style.visible) continue;
            var path: vec.Path = .{};
            defer path.deinit(self.gpa);
            if (!try self.shape(shape_node, &path)) continue;
            const mask = try vec.fillMask(self.gpa, path, child_t, style.clip_rule, self.width, self.height);
            defer mask.deinit(self.gpa);
            for (0..mask.height) |row| for (0..mask.width) |column| {
                const value = mask.alpha[row * mask.width + column];
                const out = &coverage[(mask.y + row) * self.width + mask.x + column];
                out.* = 1 - (1 - out.*) * (1 - value);
            };
        }
        // A clip path may itself be clipped.
        if (node.get("clip-path")) |value| if (parseUrl(value)) |nested| if (depth < max_depth) {
            if (try self.clipCoverage(nested, ctm, box, depth + 1)) |outer| {
                defer self.gpa.free(outer);
                for (coverage, outer) |*c, o| c.* *= o;
            }
        };
        return coverage;
    }

    fn maskCoverage(self: *Renderer, id: []const u8, ctm: vec.Transform, box: ?[4]f64, depth: u32) !?[]f32 {
        const node = self.doc.ids.get(id) orelse return null;
        if (!std.mem.eql(u8, node.name, "mask")) return null;
        const b = box orelse [4]f64{ 0, 0, 0, 0 };
        const bw = b[2] - b[0];
        const bh = b[3] - b[1];
        var content = ctm;
        if (std.mem.eql(u8, node.get("maskContentUnits") orelse "", "objectBoundingBox")) {
            if (box == null) return try self.zeros();
            content = ctm.mul(.{ .a = bw, .d = bh, .e = b[0], .f = b[1] });
        }
        const layer = try vec.Target.init(self.gpa, self.width, self.height);
        defer layer.deinit(self.gpa);
        for (node.children) |child| try self.element(layer, child, content, .{}, depth + 1);
        const coverage = try self.gpa.alloc(f32, layer.pixels.len);
        errdefer self.gpa.free(coverage);
        for (coverage, layer.pixels) |*out, pixel| {
            const r: f32 = @floatFromInt((pixel >> 16) & 255);
            const g: f32 = @floatFromInt((pixel >> 8) & 255);
            const bl: f32 = @floatFromInt(pixel & 255);
            out.* = (0.2125 * r + 0.7154 * g + 0.0721 * bl) / 255;
        }
        // Clip to the mask region (default: the bounding box grown by 10%).
        const user_units = std.mem.eql(u8, node.get("maskUnits") orelse "", "userSpaceOnUse");
        var region: [4]f64 = undefined;
        if (user_units) {
            region = .{ self.length(node, "x", .x, -0.1 * self.viewport[0]), self.length(node, "y", .y, -0.1 * self.viewport[1]), self.length(node, "width", .x, 1.2 * self.viewport[0]), self.length(node, "height", .y, 1.2 * self.viewport[1]) };
        } else {
            if (box == null) return coverage;
            const fraction = struct {
                fn f(n: *const Node, name: []const u8, default: f64) f64 {
                    const value = parseLength(n.get(name)) orelse return default;
                    return if (value.percent) value.value / 100 else value.value;
                }
            }.f;
            region = .{ b[0] + fraction(node, "x", -0.1) * bw, b[1] + fraction(node, "y", -0.1) * bh, fraction(node, "width", 1.2) * bw, fraction(node, "height", 1.2) * bh };
        }
        var outline: vec.Path = .{};
        defer outline.deinit(self.gpa);
        try outline.rect(self.gpa, region[0], region[1], region[2], region[3]);
        const clip = try vec.fillMask(self.gpa, outline, ctm, .nonzero, self.width, self.height);
        defer clip.deinit(self.gpa);
        for (0..self.height) |y| for (0..self.width) |x| {
            coverage[y * self.width + x] *= clip.at(@intCast(x), @intCast(y));
        };
        return coverage;
    }

    fn zeros(self: *Renderer) ![]f32 {
        const values = try self.gpa.alloc(f32, @as(usize, self.width) * self.height);
        @memset(values, 0);
        return values;
    }
};


/// Applies a filter made only of `feColorMatrix` primitives; other filters are skipped.
fn applyFilter(node: *const Node, layer: vec.Target) void {
    if (!std.mem.eql(u8, node.name, "filter")) return;
    var matrices: [8][20]f64 = undefined;
    var count: usize = 0;
    for (node.children) |child| {
        if (!std.mem.eql(u8, child.name, "feColorMatrix") or count >= matrices.len) return;
        matrices[count] = colorMatrix(child);
        count += 1;
    }
    if (count == 0) return;
    // Adwaita's alpha-to-white matrix: integer path. Otherwise skip transparent
    // pixels whenever the matrix keeps them transparent.
    const white = [20]f64{ 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    if (count == 1 and std.mem.eql(f64, &matrices[0], &white)) {
        for (layer.pixels) |*pixel| {
            const a = pixel.* >> 24;
            pixel.* = a * 0x01010101;
        }
        return;
    }
    var transparent_stays = true;
    for (matrices[0..count]) |m| transparent_stays = transparent_stays and m[19] <= 0;
    for (layer.pixels) |*pixel| {
        if (pixel.* == 0 and transparent_stays) continue;
        const alpha: f64 = @floatFromInt(pixel.* >> 24);
        var rgba: [4]f64 = .{ 0, 0, 0, alpha / 255 };
        if (alpha > 0) for (rgba[0..3], [_]u5{ 16, 8, 0 }) |*channel, shift| {
            channel.* = @as(f64, @floatFromInt((pixel.* >> shift) & 255)) / alpha;
        };
        for (matrices[0..count]) |m| {
            var out: [4]f64 = undefined;
            for (&out, 0..) |*value, row| {
                const r = m[row * 5 ..][0..5];
                value.* = std.math.clamp(r[0] * rgba[0] + r[1] * rgba[1] + r[2] * rgba[2] + r[3] * rgba[3] + r[4], 0, 1);
            }
            rgba = out;
        }
        pixel.* = vec.premultiply(rgba[0], rgba[1], rgba[2], rgba[3]);
    }
}

fn colorMatrix(node: *const Node) [20]f64 {
    const identity = [20]f64{ 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 };
    const kind = node.get("type") orelse "matrix";
    var scanner: Scanner = .{ .text = node.get("values") orelse "" };
    if (std.mem.eql(u8, kind, "matrix")) {
        var m: [20]f64 = undefined;
        for (&m) |*value| value.* = scanner.number() orelse return identity;
        return m;
    }
    if (std.mem.eql(u8, kind, "saturate")) {
        const s = scanner.number() orelse 1;
        return .{
            0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0,
            0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0,
            0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0,
            0,                 0,                 0,                 1, 0,
        };
    }
    if (std.mem.eql(u8, kind, "hueRotate")) {
        const angle = std.math.degreesToRadians(scanner.number() orelse 0);
        const c = @cos(angle);
        const s = @sin(angle);
        return .{
            0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0, 0,
            0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0, 0,
            0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0, 0,
            0,                             0,                             0,                             1, 0,
        };
    }
    if (std.mem.eql(u8, kind, "luminanceToAlpha")) {
        return .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.2125, 0.7154, 0.0721, 0, 0 };
    }
    return identity;
}
fn extend(box: ?[4]f64, p: vec.Point) [4]f64 {
    const b = box orelse return .{ p.x, p.y, p.x, p.y };
    return .{ @min(b[0], p.x), @min(b[1], p.y), @max(b[2], p.x), @max(b[3], p.y) };
}

fn isRenderable(name: []const u8) bool {
    const kinds = [_][]const u8{ "g", "svg", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "use", "image", "switch", "a" };
    for (kinds) |kind| if (std.mem.eql(u8, name, kind)) return true;
    return false;
}

const ImageShader = struct {
    pixels: []const u32,
    width: u32,
    height: u32,
    inverse: vec.Transform,

    fn sample(context: *const anyopaque, x: f64, y: f64) u32 {
        const self: *const ImageShader = @ptrCast(@alignCast(context));
        const p = self.inverse.apply(.{ .x = x, .y = y });
        // Bilinear filtering with edges padded from the nearest pixel.
        const fx = std.math.clamp(p.x - 0.5, 0, @as(f64, @floatFromInt(self.width - 1)));
        const fy = std.math.clamp(p.y - 0.5, 0, @as(f64, @floatFromInt(self.height - 1)));
        const x0: u32 = @intFromFloat(@floor(fx));
        const y0: u32 = @intFromFloat(@floor(fy));
        const x1 = @min(x0 + 1, self.width - 1);
        const y1 = @min(y0 + 1, self.height - 1);
        const wx = fx - @as(f64, @floatFromInt(x0));
        const wy = fy - @as(f64, @floatFromInt(y0));
        const corners = [4]u32{ self.pixels[y0 * self.width + x0], self.pixels[y0 * self.width + x1], self.pixels[y1 * self.width + x0], self.pixels[y1 * self.width + x1] };
        const weights = [4]f64{ (1 - wx) * (1 - wy), wx * (1 - wy), (1 - wx) * wy, wx * wy };
        var result: u32 = 0;
        inline for (.{ 24, 16, 8, 0 }) |shift| {
            var sum: f64 = 0;
            for (corners, weights) |pixel, weight| sum += @as(f64, @floatFromInt((pixel >> shift) & 255)) * weight;
            result |= @as(u32, @intFromFloat(@round(@min(sum, 255)))) << shift;
        }
        return result;
    }
};

const PaintState = struct {
    gradient: Gradient = .{},
    pattern: Pattern = .{},

    fn deinit(self: *PaintState, a: std.mem.Allocator) void {
        if (self.pattern.tile) |tile| tile.deinit(a);
    }
};

fn referenceChain(doc: *const Document, start: *const Node, names: []const []const u8, chain: []*const Node) []*const Node {
    var count: usize = 0;
    var node: ?*const Node = start;
    while (node) |n| {
        if (count >= chain.len) break;
        var known = false;
        for (names) |name| known = known or std.mem.eql(u8, n.name, name);
        if (!known) break;
        chain[count] = n;
        count += 1;
        const reference = n.href() orelse break;
        node = if (reference.len > 1 and reference[0] == '#') doc.ids.get(reference[1..]) else null;
    }
    return chain[0..count];
}

fn chainAttribute(chain: []const *const Node, name: []const u8) ?[]const u8 {
    for (chain) |n| if (n.get(name)) |value| return value;
    return null;
}

/// A pattern tile rendered at device resolution and repeated by wrapping.
const Pattern = struct {
    tile: ?vec.Target = null,
    inverse: vec.Transform = .identity,

    fn init(self: *Pattern, renderer: *Renderer, start: *const Node, style: Style, box: ?[4]f64, ctm: vec.Transform) !bool {
        if (renderer.pattern_depth >= 4) return false;
        var storage: [16]*const Node = undefined;
        const chain = referenceChain(renderer.doc, start, &.{"pattern"}, &storage);
        if (chain.len == 0) return false;
        const bbox_units = !std.mem.eql(u8, chainAttribute(chain, "patternUnits") orelse "", "userSpaceOnUse");
        const content_bbox = std.mem.eql(u8, chainAttribute(chain, "patternContentUnits") orelse "", "objectBoundingBox");
        const b = box orelse [4]f64{ 0, 0, 0, 0 };
        const bw = b[2] - b[0];
        const bh = b[3] - b[1];
        if ((bbox_units or content_bbox) and !(bw > 0 and bh > 0)) return false;
        var rect: [4]f64 = undefined;
        for ([_][]const u8{ "x", "y", "width", "height" }, &rect, 0..) |name, *out, i| {
            const value = parseLength(chainAttribute(chain, name)) orelse Length{ .value = 0 };
            const horizontal = i % 2 == 0;
            out.* = if (bbox_units)
                (if (value.percent) value.value / 100 else value.value) * (if (horizontal) bw else bh) + (if (i < 2) (if (horizontal) b[0] else b[1]) else 0)
            else if (value.percent)
                value.value / 100 * renderer.viewport[if (horizontal) 0 else 1]
            else
                value.value;
        }
        if (!(rect[2] > 0 and rect[3] > 0)) return false;
        var content_owner: ?*const Node = null;
        for (chain) |n| if (n.children.len > 0) {
            content_owner = n;
            break;
        };
        const owner = content_owner orelse return false;
        const placement = ctm.mul(parseTransform(chainAttribute(chain, "patternTransform"))).mul(.translate(rect[0], rect[1]));
        const s = placement.scaleFactor();
        const tw: u32 = @intFromFloat(std.math.clamp(@ceil(rect[2] * s), 1, 2048));
        const th: u32 = @intFromFloat(std.math.clamp(@ceil(rect[3] * s), 1, 2048));
        const sx = @as(f64, @floatFromInt(tw)) / rect[2];
        const sy = @as(f64, @floatFromInt(th)) / rect[3];
        var content: vec.Transform = .identity;
        if (chainAttribute(chain, "viewBox")) |value| {
            var view: [4]f64 = undefined;
            var scanner: Scanner = .{ .text = value };
            for (&view) |*number| number.* = scanner.number() orelse 0;
            if (view[2] > 0 and view[3] > 0) content = viewportTransform(view, .{ 0, 0, rect[2], rect[3] }, parseAspect(chainAttribute(chain, "preserveAspectRatio")));
        } else if (content_bbox) {
            content = .{ .a = bw, .d = bh };
        }
        const tile = try vec.Target.init(renderer.gpa, tw, th);
        self.tile = tile;
        var sub = renderer.*;
        // The copy gets its own cache so growing it cannot invalidate the original.
        sub.boxes = .empty;
        defer sub.boxes.deinit(renderer.gpa);
        sub.width = tw;
        sub.height = th;
        sub.pattern_depth += 1;
        var arena: std.heap.ArenaAllocator = .init(renderer.gpa);
        defer arena.deinit();
        const pattern_style = renderer.compute(arena.allocator(), owner, style);
        for (owner.children) |child| try sub.element(tile, child, vec.Transform.scale(sx, sy).mul(content), pattern_style, 1);
        self.inverse = placement.mul(.scale(1 / sx, 1 / sy)).invert() orelse return false;
        return true;
    }

    fn sample(context: *const anyopaque, x: f64, y: f64) u32 {
        const self: *const Pattern = @ptrCast(@alignCast(context));
        const tile = self.tile.?;
        const p = self.inverse.apply(.{ .x = x, .y = y });
        const w: f64 = @floatFromInt(tile.width);
        const h: f64 = @floatFromInt(tile.height);
        const px: u32 = @intFromFloat(@min(@mod(@floor(p.x), w), w - 1));
        const py: u32 = @intFromFloat(@min(@mod(@floor(p.y), h), h - 1));
        return tile.pixels[py * tile.stride + px];
    }
};

const Gradient = struct {
    lut: [256]u32 = undefined,
    single: ?u32 = null,
    inverse: vec.Transform = .identity,
    radial: bool = false,
    spread: enum { pad, reflect, repeat } = .pad,
    // Linear: start and end. Radial: center, radius and focus.
    x1: f64 = 0,
    y1: f64 = 0,
    x2: f64 = 0,
    y2: f64 = 0,
    r: f64 = 0,

    /// Resolves attributes along the `href` chain and builds the color table.
    fn init(self: *Gradient, renderer: *Renderer, start: *const Node, style: Style, box: ?[4]f64, ctm: vec.Transform) bool {
        self.* = .{};
        const doc = renderer.doc;
        var chain: [16]*const Node = undefined;
        var count: usize = 0;
        var node: ?*const Node = start;
        while (node) |n| {
            if (count >= chain.len) break;
            if (!std.mem.eql(u8, n.name, "linearGradient") and !std.mem.eql(u8, n.name, "radialGradient")) break;
            chain[count] = n;
            count += 1;
            const reference = n.href() orelse break;
            node = if (reference.len > 1 and reference[0] == '#') doc.ids.get(reference[1..]) else null;
        }
        if (count == 0) return false;
        const nodes = chain[0..count];
        const lookup = struct {
            fn f(list: []const *const Node, name: []const u8) ?[]const u8 {
                for (list) |n| if (n.get(name)) |value| return value;
                return null;
            }
        }.f;
        self.radial = std.mem.eql(u8, nodes[0].name, "radialGradient");
        const bbox_units = !std.mem.eql(u8, lookup(nodes, "gradientUnits") orelse "", "userSpaceOnUse");
        const spread = lookup(nodes, "spreadMethod") orelse "pad";
        self.spread = if (std.mem.eql(u8, spread, "reflect")) .reflect else if (std.mem.eql(u8, spread, "repeat")) .repeat else .pad;

        var stops_node: ?*const Node = null;
        for (nodes) |n| {
            for (n.children) |child| if (std.mem.eql(u8, child.name, "stop")) {
                stops_node = n;
                break;
            };
            if (stops_node != null) break;
        }
        const owner = stops_node orelse return false;
        var arena: std.heap.ArenaAllocator = .init(renderer.gpa);
        defer arena.deinit();
        const Stop = struct { offset: f64, rgba: [4]f64 };
        var stops: [64]Stop = undefined;
        var stop_count: usize = 0;
        var last_offset: f64 = 0;
        for (owner.children) |child| {
            if (!std.mem.eql(u8, child.name, "stop") or stop_count >= stops.len) continue;
            const stop_style = renderer.compute(arena.allocator(), child, style);
            const color = switch (stop_style.stop_color) {
                .none => Color{ .rgb = 0, .alpha = 0 },
                .current => stop_style.color,
                .color => |value| value,
            };
            const offset = @max(last_offset, std.math.clamp(parseNumber(child.get("offset") orelse "0") orelse 0, 0, 1));
            last_offset = offset;
            stops[stop_count] = .{ .offset = offset, .rgba = .{ color.channel(16), color.channel(8), color.channel(0), color.alpha * stop_style.stop_opacity } };
            stop_count += 1;
        }
        if (stop_count == 0) return false;
        const list = stops[0..stop_count];
        if (stop_count == 1) {
            const c = list[0].rgba;
            self.single = vec.premultiply(c[0], c[1], c[2], c[3]);
            return true;
        }
        for (&self.lut, 0..) |*entry, i| {
            const t = @as(f64, @floatFromInt(i)) / 255;
            var c = list[0].rgba;
            if (t >= list[list.len - 1].offset) {
                c = list[list.len - 1].rgba;
            } else if (t > list[0].offset) {
                for (list[0 .. list.len - 1], list[1..]) |lo, hi| {
                    if (t >= lo.offset and t <= hi.offset) {
                        const span = hi.offset - lo.offset;
                        const w = if (span > 1e-9) (t - lo.offset) / span else 1;
                        for (&c, lo.rgba, hi.rgba) |*out, l, h| out.* = l + (h - l) * w;
                        break;
                    }
                }
            }
            entry.* = vec.premultiply(c[0], c[1], c[2], c[3]);
        }

        const coordinate = struct {
            fn f(r: *const Renderer, chain_nodes: []const *const Node, name: []const u8, default: f64, bbox: bool, axis: enum { x, y, other }) f64 {
                const value = parseLength(lookup(chain_nodes, name)) orelse return default;
                if (bbox) return if (value.percent) value.value / 100 else value.value;
                if (!value.percent) return value.value;
                const basis = switch (axis) {
                    .x => r.viewport[0],
                    .y => r.viewport[1],
                    .other => @sqrt((r.viewport[0] * r.viewport[0] + r.viewport[1] * r.viewport[1]) / 2),
                };
                return value.value / 100 * basis;
            }
        }.f;
        if (self.radial) {
            const cx = coordinate(renderer, nodes, "cx", if (bbox_units) 0.5 else renderer.viewport[0] / 2, bbox_units, .x);
            const cy = coordinate(renderer, nodes, "cy", if (bbox_units) 0.5 else renderer.viewport[1] / 2, bbox_units, .y);
            self.r = coordinate(renderer, nodes, "r", if (bbox_units) 0.5 else renderer.viewport[0] / 2, bbox_units, .other);
            self.x1 = cx;
            self.y1 = cy;
            self.x2 = coordinate(renderer, nodes, "fx", cx, bbox_units, .x);
            self.y2 = coordinate(renderer, nodes, "fy", cy, bbox_units, .y);
            // Keep the focus inside the circle.
            const dx = self.x2 - cx;
            const dy = self.y2 - cy;
            const distance = @sqrt(dx * dx + dy * dy);
            if (distance > self.r * 0.999 and distance > 0) {
                self.x2 = cx + dx / distance * self.r * 0.999;
                self.y2 = cy + dy / distance * self.r * 0.999;
            }
        } else {
            self.x1 = coordinate(renderer, nodes, "x1", 0, bbox_units, .x);
            self.y1 = coordinate(renderer, nodes, "y1", 0, bbox_units, .y);
            self.x2 = coordinate(renderer, nodes, "x2", if (bbox_units) 1 else renderer.viewport[0], bbox_units, .x);
            self.y2 = coordinate(renderer, nodes, "y2", 0, bbox_units, .y);
        }
        var t = ctm;
        if (bbox_units) {
            const b = box orelse return false;
            const bw = b[2] - b[0];
            const bh = b[3] - b[1];
            if (!(bw > 0 and bh > 0)) return false;
            t = t.mul(.{ .a = bw, .d = bh, .e = b[0], .f = b[1] });
        }
        t = t.mul(parseTransform(lookup(nodes, "gradientTransform")));
        self.inverse = t.invert() orelse return false;
        const degenerate = if (self.radial) !(self.r > 0) else (self.x1 == self.x2 and self.y1 == self.y2);
        if (degenerate) self.single = self.lut[255];
        return true;
    }

    fn sample(context: *const anyopaque, x: f64, y: f64) u32 {
        const self: *const Gradient = @ptrCast(@alignCast(context));
        const p = self.inverse.apply(.{ .x = x, .y = y });
        var t: f64 = undefined;
        if (self.radial) {
            // Find t where p lies on the circle centered at f + t(c − f) with radius t·r.
            const dx = self.x1 - self.x2;
            const dy = self.y1 - self.y2;
            const px = p.x - self.x2;
            const py = p.y - self.y2;
            const qa = dx * dx + dy * dy - self.r * self.r;
            const qb = px * dx + py * dy;
            const qc = px * px + py * py;
            t = (qb - @sqrt(@max(0, qb * qb - qa * qc))) / qa;
        } else {
            const dx = self.x2 - self.x1;
            const dy = self.y2 - self.y1;
            t = ((p.x - self.x1) * dx + (p.y - self.y1) * dy) / (dx * dx + dy * dy);
        }
        if (!std.math.isFinite(t)) t = 0;
        t = switch (self.spread) {
            .pad => std.math.clamp(t, 0, 1),
            .repeat => t - @floor(t),
            .reflect => blk: {
                const m = @mod(t, 2);
                break :blk if (m > 1) 2 - m else m;
            },
        };
        return self.lut[@intFromFloat(@round(t * 255))];
    }
};

// ---------------------------------------------------------------- Path data

fn parsePathData(a: std.mem.Allocator, data: []const u8, path: *vec.Path) !void {
    var s: Scanner = .{ .text = data };
    var command: u8 = 0;
    var current: vec.Point = .{ .x = 0, .y = 0 };
    var start = current;
    var control: ?vec.Point = null;
    var previous: u8 = 0;
    while (true) {
        const next = s.peek() orelse break;
        if (std.ascii.isAlphabetic(next) and next != 'e' and next != 'E') {
            command = next;
            s.i += 1;
        } else if (command == 0) {
            return;
        } else if (command == 'M') {
            command = 'L';
        } else if (command == 'm') {
            command = 'l';
        } else if (command == 'Z' or command == 'z') {
            return;
        }
        const relative = std.ascii.isLower(command);
        const base = if (relative) current else vec.Point{ .x = 0, .y = 0 };
        switch (std.ascii.toUpper(command)) {
            'M' => {
                const p = point(&s, base) orelse return;
                try path.moveTo(a, p);
                current = p;
                start = p;
            },
            'L' => {
                const p = point(&s, base) orelse return;
                try path.lineTo(a, p);
                current = p;
            },
            'H' => {
                const x = s.number() orelse return;
                current = .{ .x = if (relative) current.x + x else x, .y = current.y };
                try path.lineTo(a, current);
            },
            'V' => {
                const y = s.number() orelse return;
                current = .{ .x = current.x, .y = if (relative) current.y + y else y };
                try path.lineTo(a, current);
            },
            'C' => {
                const c1 = point(&s, base) orelse return;
                const c2 = point(&s, base) orelse return;
                const p = point(&s, base) orelse return;
                try path.cubicTo(a, c1, c2, p);
                control = c2;
                current = p;
            },
            'S' => {
                const c1 = if (control != null and (previous == 'C' or previous == 'S')) reflect(control.?, current) else current;
                const c2 = point(&s, base) orelse return;
                const p = point(&s, base) orelse return;
                try path.cubicTo(a, c1, c2, p);
                control = c2;
                current = p;
            },
            'Q' => {
                const c = point(&s, base) orelse return;
                const p = point(&s, base) orelse return;
                try path.quadTo(a, c, p);
                control = c;
                current = p;
            },
            'T' => {
                const c = if (control != null and (previous == 'Q' or previous == 'T')) reflect(control.?, current) else current;
                const p = point(&s, base) orelse return;
                try path.quadTo(a, c, p);
                control = c;
                current = p;
            },
            'A' => {
                const rx = s.number() orelse return;
                const ry = s.number() orelse return;
                const rotation = s.number() orelse return;
                const large = s.flag() orelse return;
                const sweep = s.flag() orelse return;
                const p = point(&s, base) orelse return;
                if (path.current == null) try path.moveTo(a, current);
                try path.svgArc(a, rx, ry, rotation, large, sweep, p);
                current = p;
            },
            'Z' => {
                try path.close(a);
                current = start;
            },
            else => return,
        }
        previous = std.ascii.toUpper(command);
        if (s.failed) return;
    }
}

fn point(s: *Scanner, base: vec.Point) ?vec.Point {
    const x = s.number() orelse return null;
    const y = s.number() orelse return null;
    return .{ .x = base.x + x, .y = base.y + y };
}

fn reflect(control: vec.Point, around: vec.Point) vec.Point {
    return .{ .x = 2 * around.x - control.x, .y = 2 * around.y - control.y };
}

// ---------------------------------------------------------------- Tests

fn renderTest(svg: []const u8, width: u32, height: u32, options: Options) ![]u32 {
    const a = std.testing.allocator;
    const doc = try Document.parse(a, svg);
    defer doc.deinit();
    const target = try vec.Target.init(a, width, height);
    errdefer target.deinit(a);
    try doc.render(a, target, options);
    return target.pixels;
}

test "SVG sizes come from absolute dimensions or the viewBox" {
    const a = std.testing.allocator;
    const cases = [_]struct { svg: []const u8, size: ?[2]f64 }{
        .{ .svg = "<svg width='16' height='24'/>", .size = .{ 16, 24 } },
        .{ .svg = "<svg width='12pt' height='1in'/>", .size = .{ 16, 96 } },
        .{ .svg = "<svg width='100%' viewBox='0 0 32 8'/>", .size = .{ 32, 8 } },
        .{ .svg = "<svg viewBox='0,0,4,2'></svg>", .size = .{ 4, 2 } },
        .{ .svg = "<svg/>", .size = null },
    };
    for (cases) |case| {
        const doc = try Document.parse(a, case.svg);
        defer doc.deinit();
        try std.testing.expectEqual(case.size, doc.size());
    }
    try std.testing.expectError(error.InvalidSvg, Document.parse(a, "<html/>"));
    try std.testing.expectError(error.InvalidSvg, Document.parse(a, "<svg><g></svg>"));
}

test "SVG shapes, transforms, CSS classes and entities render with expected colors" {
    const a = std.testing.allocator;
    const svg =
        \\<?xml version="1.0"?>
        \\<!DOCTYPE svg [ <!ENTITY red "#ff0000"> ]>
        \\<!-- comment -->
        \\<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8" viewBox="0 0 4 4">
        \\  <style><![CDATA[ .blue { fill: blue } rect#g { fill: rgb(0, 100%, 0) } ]]></style>
        \\  <rect width="2" height="2" fill="&red;"/>
        \\  <rect x="2" width="2" height="2" class="blue" fill="red"/>
        \\  <g transform="translate(0 2)"><rect id="g" width="2" height="2"/></g>
        \\  <path d="M2,2h2v2h-2z" style="fill:#fff;fill-opacity:.5"/>
        \\</svg>
    ;
    const pixels = try renderTest(svg, 8, 8, .{});
    defer a.free(pixels);
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[1 * 8 + 1]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[1 * 8 + 6]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), pixels[6 * 8 + 1]);
    try std.testing.expectEqual(@as(u32, 0x80808080), pixels[6 * 8 + 6]);
}

test "SVG path data handles relative, smooth, arc and compact number syntax" {
    const a = std.testing.allocator;
    var path: vec.Path = .{};
    defer path.deinit(a);
    try parsePathData(a, "m1.5.5l1-1 1e1,0Q3 3 4 4t1 1s1 1 2 2a1 1 0 011 1zh2V1", &path);
    const verbs = [_]vec.Path.Verb{ .move, .line, .line, .quad, .quad, .cubic };
    try std.testing.expectEqualSlices(vec.Path.Verb, &verbs, path.verbs.items[0..verbs.len]);
    try std.testing.expectEqual(vec.Point{ .x = 1.5, .y = 0.5 }, path.points.items[0]);
    try std.testing.expectEqual(vec.Point{ .x = 12.5, .y = -0.5 }, path.points.items[2]);
    try std.testing.expectEqual(vec.Point{ .x = 3.5, .y = 1 }, path.current.?);
}

test "SVG symbolic recoloring follows GTK classes and opacity" {
    const a = std.testing.allocator;
    const svg =
        \\<svg width="4" height="2">
        \\  <rect width="1" height="2" fill="#123456"/>
        \\  <rect x="1" width="1" height="2" class="error"/>
        \\  <path d="M2 0h1v2h-1z" class="success"/>
        \\  <circle cx="3.5" cy="1" r="5" class="stroke" style="fill:red" stroke-width="0"/>
        \\</svg>
    ;
    const pixels = try renderTest(svg, 4, 2, .{ .symbolic = .{ .foreground = .{ .rgb = 0xffffff } }, .opacity = 1 });
    defer a.free(pixels);
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xffcc0000), pixels[1]);
    try std.testing.expectEqual(@as(u32, 0xff4e9a06), pixels[2]);
    // The stroke-classed circle is not filled.
    try std.testing.expectEqual(@as(u32, 0), pixels[3]);
    const faded = try renderTest(svg, 4, 2, .{ .symbolic = .{ .foreground = .{ .rgb = 0xffffff } }, .opacity = 0.5 });
    defer a.free(faded);
    try std.testing.expectEqual(@as(u32, 0x80808080), faded[0]);
}

test "SVG gradients, use, clip paths, masks and group opacity" {
    const a = std.testing.allocator;
    const svg =
        \\<svg xmlns:xlink="http://www.w3.org/1999/xlink" width="100" height="10">
        \\  <defs>
        \\    <linearGradient id="base"><stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#fff"/></linearGradient>
        \\    <linearGradient id="ramp" xlink:href="#base"/>
        \\    <radialGradient id="dot"><stop offset="0" stop-color="red"/><stop offset="100%" stop-color="red" stop-opacity="0"/></radialGradient>
        \\    <clipPath id="left"><rect width="50" height="10"/></clipPath>
        \\    <mask id="half"><rect width="100" height="10" fill="#808080"/></mask>
        \\    <rect id="cell" width="10" height="10" fill="lime"/>
        \\  </defs>
        \\  <rect width="100" height="5" fill="url(#ramp)" clip-path="url(#left)"/>
        \\  <use xlink:href="#cell" x="60" y="5"/>
        \\  <g opacity="0.5"><rect x="80" y="5" width="10" height="5" fill="blue"/><rect x="85" y="5" width="10" height="5" fill="blue"/></g>
        \\  <rect x="0" y="5" width="10" height="5" fill="white" mask="url(#half)"/>
        \\  <circle cx="30" cy="7.5" r="2.5" fill="url(#dot)"/>
        \\</svg>
    ;
    const pixels = try renderTest(svg, 100, 10, .{});
    defer a.free(pixels);
    const at = struct {
        fn f(p: []const u32, x: usize, y: usize) u32 {
            return p[y * 100 + x];
        }
    }.f;
    // The ramp brightens left to right and is clipped at x = 50.
    try std.testing.expect((at(pixels, 10, 2) & 255) < (at(pixels, 40, 2) & 255));
    try std.testing.expectEqual(@as(u32, 0xff), at(pixels, 40, 2) >> 24);
    try std.testing.expectEqual(@as(u32, 0), at(pixels, 60, 2));
    try std.testing.expectEqual(@as(u32, 0xff00ff00), at(pixels, 65, 7));
    // Overlapping shapes in a translucent group do not double their opacity.
    try std.testing.expectEqual(at(pixels, 82, 7), at(pixels, 87, 7));
    try std.testing.expectEqual(@as(u32, 0x80), at(pixels, 87, 7) >> 24);
    // A mid-gray luminance mask halves the white rectangle.
    const masked = at(pixels, 5, 7) >> 24;
    try std.testing.expect(masked > 0x70 and masked < 0x90);
    // The radial gradient is opaque at its center and fades outward.
    try std.testing.expect(at(pixels, 30, 7) >> 24 > at(pixels, 31, 9) >> 24);
}

test "SVG embedded PNG images are drawn scaled" {
    const a = std.testing.allocator;
    const pixel = [_]u32{0xff00ff00};
    const encoded = try png.encode(a, .{ .pixels = std.mem.sliceAsBytes(&pixel), .width = 1, .height = 1, .stride = 4, .alpha = true });
    defer a.free(encoded);
    const base64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(encoded.len));
    defer a.free(base64);
    _ = std.base64.standard.Encoder.encode(base64, encoded);
    const svg = try std.fmt.allocPrint(a, "<svg width='4' height='4'><image width='4' height='4' href='data:image/png;base64,{s}'/></svg>", .{base64});
    defer a.free(svg);
    const pixels = try renderTest(svg, 4, 4, .{});
    defer a.free(pixels);
    for (pixels) |value| try std.testing.expectEqual(@as(u32, 0xff00ff00), value);
}
