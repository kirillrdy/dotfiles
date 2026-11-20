"""Generate typed Zig Wayland client bindings for desktop-wire.zig from protocol XML.

Each interface becomes a struct holding a `wire.Proxy` with one method per
request, an `Event` union in opcode order and `listen` for typed handlers.
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

KINDS = {"int": "i", "uint": "u", "fixed": "f", "string": "s",
         "object": "o", "new_id": "n", "array": "a", "fd": "h"}
KEYWORDS = {"error", "type", "fn", "const", "var", "return", "align", "and", "or",
            "struct", "enum", "union", "test", "export", "extern", "async", "await",
            "resume", "suspend", "break", "continue", "defer", "if", "else", "for",
            "while", "switch", "true", "false", "null", "undefined", "pub", "try",
            "catch", "orelse", "inline", "comptime", "opaque", "packed", "noalias",
            "anytype", "anyframe", "callconv", "linksection", "threadlocal", "usingnamespace",
            "volatile", "allowzero", "asm", "errdefer", "unreachable", "nosuspend"}


def ident(name):
    if name in KEYWORDS or not (name[0].isalpha() or name[0] == "_"):
        return f'@"{name}"'
    return name


def camel(name):
    return "".join(part[:1].upper() + part[1:] for part in name.split("_"))


def signature(message):
    sig = ""
    for arg in message.findall("arg"):
        kind = arg.attrib["type"]
        if kind == "new_id" and arg.get("interface") is None:
            sig += "sun"
            continue
        sig += ("?" if arg.get("allow-null") == "true" else "") + KINDS[kind]
    return sig


def event_type(arg, known):
    kind = arg.attrib["type"]
    nullable = arg.get("allow-null") == "true"
    target = arg.get("interface")
    if kind == "int":
        return "i32"
    if kind == "uint":
        return "u32"
    if kind == "fixed":
        return "f64"
    if kind == "string":
        return "?[:0]const u8" if nullable else "[:0]const u8"
    if kind == "array":
        return "[]const u8"
    if kind == "fd":
        return "wire.Fd"
    if kind in ("object", "new_id"):
        base = target if target in known else "wire.Proxy"
        return ("?" if nullable else "") + base
    raise ValueError(kind)


def request_type(arg, known):
    kind = arg.attrib["type"]
    if kind == "string":
        return "?[:0]const u8" if arg.get("allow-null") == "true" else "[:0]const u8"
    if kind == "array":
        return "[]const u8"
    if kind == "fd":
        return "i32"
    return event_type(arg, known)


def messages(interface, tag, known):
    out = []
    for message in interface.findall(tag):
        new_id = None
        for arg in message.findall("arg"):
            if arg.attrib["type"] == "new_id" and arg.get("interface") in known:
                new_id = arg.get("interface")
        resolver = f"&{new_id}.interface" if new_id else "null"
        out.append('.{ .name = "' + message.attrib["name"] + '", .signature = "' + signature(message) + '", .since = '
                   + message.get("since", "1") + ", .destructor = " + ("true" if message.get("type") == "destructor" else "false")
                   + (", .new_id = struct { fn get() *const wire.Interface { return " + resolver + "; } }.get" if new_id else "") + " }")
    return out


def generate(paths):
    interfaces = []
    for path in paths:
        interfaces.extend(ET.parse(path).getroot().findall("interface"))
    known = {node.attrib["name"] for node in interfaces}
    lines = ["// Generated from protocol XML by tools/wayland-zig.py. Do not edit.",
             'const wire = @import("wayland-wire");']
    for interface in interfaces:
        name = interface.attrib["name"]
        requests = interface.findall("request")
        events = interface.findall("event")
        lines.append(f"pub const {name} = struct {{")
        lines.append("    proxy: wire.Proxy,")
        lines.append(f"    const Self = @This();")
        lines.append(f'    pub const interface: wire.Interface = .{{ .name = "{name}", .version = {interface.attrib["version"]}, '
                     ".requests = &.{ " + ", ".join(messages(interface, "request", known)) + " }, "
                     ".events = &.{ " + ", ".join(messages(interface, "event", known)) + " } };")
        lines.append("    pub const Event = union(enum) {")
        for event in events:
            fields = ", ".join(f"{ident(arg.attrib['name'])}: {event_type(arg, known)}" for arg in event.findall("arg"))
            lines.append(f"        {ident(event.attrib['name'])}: struct {{ {fields} }},")
        lines.append("    };")
        # Parameters must not shadow the struct's own declarations.
        taken = {"Self", "Event", "interface", "listen", "version", "destroy", "proxy", "wire"}
        taken |= {request.attrib["name"] for request in requests}
        taken |= {camel(enum.attrib["name"]) for enum in interface.findall("enum")}
        for enum in interface.findall("enum"):
            lines.append(f"    pub const {camel(enum.attrib['name'])} = struct {{")
            for entry in enum.findall("entry"):
                lines.append(f"        pub const {ident(entry.attrib['name'])}: u32 = {entry.attrib['value']};")
            lines.append("    };")
        lines.append("    pub fn listen(self: Self, comptime Data: type, data: *Data, comptime handler: fn (*Data, Self, Event) void) void {")
        lines.append("        self.proxy.listen(Self, Data, data, handler);")
        lines.append("    }")
        lines.append("    pub fn version(self: Self) u32 {")
        lines.append("        return self.proxy.version();")
        lines.append("    }")
        has_destroy = False
        for opcode, request in enumerate(requests):
            rname = request.attrib["name"]
            has_destroy |= rname == "destroy"
            params = ["self: Self"]
            values = []
            returns = "void"
            new_interface = "null"
            untyped = False
            for arg in request.findall("arg"):
                kind = arg.attrib["type"]
                raw = arg.attrib["name"]
                aname = ident(raw + "_value" if raw in taken else raw)
                if kind == "new_id":
                    target = arg.get("interface")
                    if target is None:
                        untyped = True
                        params.append("comptime T: type")
                        params.append("bind_version: u32")
                        values.extend(["T.interface.name", "bind_version", "wire.new_id"])
                        returns = "T"
                        new_interface = "&T.interface"
                    else:
                        values.append("wire.new_id")
                        returns = target if target in known else "wire.Proxy"
                        new_interface = f"&{target}.interface" if target in known else "null"
                    continue
                params.append(f"{aname}: {request_type(arg, known)}")
                values.append(aname)
            version = "bind_version" if untyped else "null"
            call = f"self.proxy.send({opcode}, interface.requests[{opcode}], {new_interface}, {version}, .{{ {', '.join(values)} }})"
            lines.append(f"    pub fn {ident(rname)}({', '.join(params)}) {returns} {{")
            if returns == "void":
                lines.append(f"        _ = {call};")
            elif returns == "wire.Proxy":
                lines.append(f"        return {call};")
            else:
                lines.append(f"        return .{{ .proxy = {call} }};")
            lines.append("    }")
        if not has_destroy:
            lines.append("    /// Forgets the object locally; the protocol has no destructor request.")
            lines.append("    pub fn destroy(self: Self) void {")
            lines.append("        self.proxy.forget();")
            lines.append("    }")
        lines.append("};")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    output, *paths = sys.argv[1:]
    Path(output).write_text(generate(paths))
