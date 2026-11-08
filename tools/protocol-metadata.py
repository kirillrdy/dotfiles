"""Generate native Zig Wayland metadata; wayland-scanner remains the test oracle."""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def generate(paths, selected):
    interfaces = {
        node.attrib["name"]: node
        for path in paths
        for node in ET.parse(path).getroot().findall("interface")
    }
    missing = selected - interfaces.keys()
    if missing:
        raise ValueError(f"Interfaces missing from XML: {sorted(missing)}")
    external = set()
    lines = ["// Generated from protocol XML. Do not edit.",
             "pub fn Metadata(comptime c: type) type { return struct {",
             "const Interface = c.struct_wl_interface;",
             "const Message = c.struct_wl_message;"]
    kinds = {"int": "i", "uint": "u", "fixed": "f", "string": "s",
             "object": "o", "new_id": "n", "array": "a", "fd": "h"}
    for name in sorted(selected):
        interface = interfaces[name]
        for tag in ("request", "event"):
            messages = interface.findall(tag)
            lines.append(f"const {name}_{tag}s = [_]Message{{")
            for message in messages:
                since = int(message.get("since", "1"))
                signature = str(since) if since > 1 else ""
                types = []
                for arg in message.findall("arg"):
                    kind = arg.attrib["type"]
                    target = arg.get("interface")
                    if kind == "new_id" and target is None:
                        # Untyped new_id carries an interface name and version.
                        signature += "su"
                        types.extend(["null", "null"])
                    signature += ("?" if arg.get("allow-null") == "true" else "") + kinds[kind]
                    types.append(f"&{target}_interface" if target else "null")
                    if target and target not in selected:
                        external.add(target)
                table = "@constCast(&[_][*c]const Interface{" + ",".join(types) + "})" if types else "null"
                lines.append('.{ .name = "' + message.attrib["name"] + '", .signature = "' + signature + '", .types = ' + table + ' },')
            lines.append("};")
        requests = len(interface.findall("request"))
        events = len(interface.findall("event"))
        lines.append(f'pub export const {name}_interface: Interface = .{{ .name = "{name}", .version = {interface.attrib["version"]}, '
                     f'.method_count = {requests}, .methods = &{name}_requests, .event_count = {events}, .events = &{name}_events }};')
    for name in sorted(external):
        lines.append(f"extern const {name}_interface: Interface;")
    lines.append("}; }")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    output, names, *paths = sys.argv[1:]
    Path(output).write_text(generate(paths, set(name.removesuffix("_interface") for name in names.split(","))))
