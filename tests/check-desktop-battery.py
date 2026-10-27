"""Exercise native battery updates with a private D-Bus and the real quick-settings widgets."""
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import subprocess as sp
import sys
import tempfile
import threading
import time
from gi.repository import Gio, GLib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--fixture", required=True)
parser.add_argument("--dbus-config", required=True)
parser.add_argument("--serve-upower", action="store_true")
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="desktop-battery-check-", dir="/tmp"))
print(f"Artifacts: {root}", flush=True)
loop = GLib.MainLoop()
thread = threading.Thread(target=loop.run, daemon=True)
thread.start()
name = "org.freedesktop.UPower"
path = "/org/freedesktop/UPower/devices/DisplayDevice"
interface = name + ".Device"
properties = {"IsPresent": GLib.Variant("b", True), "Percentage": GLib.Variant("d", 72.0),
              "State": GLib.Variant("u", 2), "TimeToEmpty": GLib.Variant("x", 9000),
              "TimeToFull": GLib.Variant("x", 0), "ChargeThresholdEnabled": GLib.Variant("b", False)}
xml = '<node><interface name="' + interface + '">' + ''.join(
    f'<property name="{key}" type="{value.get_type_string()}" access="read"/>'
    for key, value in properties.items()) + '</interface></node>'


if args.serve_upower:
    conn = Gio.DBusConnection.new_for_address_sync(os.environ["DBUS_STARTER_ADDRESS"],
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
        None, None)
    conn.set_exit_on_close(False)
    conn.connect("closed", lambda *_: loop.quit())
    conn.register_object(path, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0],
        None, lambda conn, sender, obj, iface, prop: properties[prop], None)
    conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
        "RequestName", GLib.Variant("(su)", (name, 0)), GLib.VariantType("(u)"), 0, 3000, None)
    thread.join()
    raise SystemExit(0)


activation_dir = root / "services"
activation_dir.mkdir()
activation_command = ' '.join('"' + arg.replace('\\', '\\\\').replace('"', '\\"') + '"' for arg in
    [sys.executable, str(Path(__file__).resolve()), "--fixture", args.fixture,
     "--dbus-config", args.dbus_config, "--serve-upower"])
(activation_dir / (name + ".service")).write_text(
    f"[D-BUS Service]\nName={name}\nExec={activation_command}\n")
activation_config = root / "activation.conf"
activation_config.write_text(Path(args.dbus_config).read_text().replace(
    "</busconfig>", f"<servicedir>{activation_dir}</servicedir></busconfig>"))


def start_bus(activate=False):
    config = str(activation_config) if activate else args.dbus_config
    bus = sp.Popen(["dbus-daemon", "--nofork", "--print-address=1", "--config-file=" + config,
                    "--address=unix:path=" + str(root / "bus")], stdout=sp.PIPE, stderr=sp.PIPE, text=True)
    address = bus.stdout.readline().strip()
    assert address, bus.stderr.read()
    return bus, address


bus, address = start_bus()
env = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=address.split(",guid=")[0], G_DEBUG="fatal-criticals", GSETTINGS_BACKEND="memory")
service = None
process = None
errors = []


class UPower:
    def __init__(self, values):
        self.values = values
        self.conn = Gio.DBusConnection.new_for_address_sync(address,
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None, None)
        self.conn.set_exit_on_close(False)
        self.registration = self.conn.register_object(path, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0],
            None, lambda conn, sender, obj, iface, prop: self.values[prop], None)
        self.conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "RequestName", GLib.Variant("(su)", (name, 0)), GLib.VariantType("(u)"), 0, 3000, None)

    def update(self, changes, invalidated=()):
        self.values.update(changes)
        changed = {key: value for key, value in changes.items() if key not in invalidated}
        self.conn.emit_signal(None, path, "org.freedesktop.DBus.Properties", "PropertiesChanged",
            GLib.Variant("(sa{sv}as)", (interface, changed, list(invalidated))))
        self.conn.flush_sync(None)

    def close(self):
        self.conn.unregister_object(self.registration)
        self.conn.close_sync(None)


updates = queue.Queue()


def read_updates():
    for line in process.stdout:
        try:
            updates.put(json.loads(line))
        except Exception as error:
            errors.append(repr(error))


def expect(check, description, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert not errors, errors
        assert process.poll() is None, (root / "fixture.log").read_text()
        try:
            value = updates.get(timeout=0.05)
        except queue.Empty:
            continue
        if check(value):
            return value
    raise AssertionError(description)


try:
    # Cancel proxy construction before the first async completion.
    sp.run([args.fixture, "--dispose"], env=env, check=True, timeout=5, capture_output=True)
    with (root / "fixture.log").open("w") as log:
        process = sp.Popen([args.fixture], env=env, stdout=sp.PIPE, stderr=log, text=True)
    reader = threading.Thread(target=read_updates, daemon=True)
    reader.start()
    expect(lambda s: not s["present"] and not s["visible"], "missing UPower should hide the battery")
    service = UPower(dict(properties))
    expect(lambda s: s["visible"] and s["text"] == "72%" and s["duration"] == "2∶30", "initial properties")
    service.update({"Percentage": GLib.Variant("d", 85.0), "State": GLib.Variant("u", 1),
                    "TimeToFull": GLib.Variant("x", 3720)})
    expect(lambda s: s["visible"] and s["text"] == "85%" and s["icon"] == "battery-level-80-charging-symbolic"
           and s["duration"] == "1∶02", "live charging state")
    service.update({"Percentage": GLib.Variant("d", 100.0), "State": GLib.Variant("u", 4)})
    expect(lambda s: s["text"] == "100%" and s["icon"] == "battery-level-100-charged-symbolic"
           and not s["duration"], "charged state clears the old estimate")
    service.update({"Percentage": GLib.Variant("d", 80.0), "State": GLib.Variant("u", 5),
                    "ChargeThresholdEnabled": GLib.Variant("b", True)})
    expect(lambda s: s["text"] == "80%" and s["icon"] == "battery-level-80-plugged-in-symbolic", "charge limit")
    service.update({"Percentage": GLib.Variant("d", 63.0)}, invalidated=("Percentage",))
    expect(lambda s: s["text"] == "63%", "invalidated properties are fetched again")
    for percent in (float("nan"), float("inf"), -1.0, 101.0):
        service.update({"Percentage": GLib.Variant("d", percent)})
        expect(lambda s: not s["present"] and not s["visible"], "invalid percentage hides the battery")
        service.update({"Percentage": GLib.Variant("d", 50.0)})
        expect(lambda s: s["visible"] and s["text"] == "50%", "valid percentage recovers")
    service.update({"IsPresent": GLib.Variant("b", False)})
    expect(lambda s: not s["visible"], "absent display battery")
    service.close()
    service = None
    expect(lambda s: not s["present"] and not s["visible"], "service disappearance clears stale data")
    new_properties = dict(properties, Percentage=GLib.Variant("d", 33.0))
    service = UPower(new_properties)
    expect(lambda s: s["present"] and s["text"] == "33%", "new service owner restores reporting")
    service.close()
    service = None
    bus.terminate()
    bus.wait(timeout=5)
    expect(lambda s: not s["present"] and not s["visible"], "system bus disconnect clears reporting", timeout=12)
    bus, restarted_address = start_bus()
    assert restarted_address.split(",guid=")[0] == address.split(",guid=")[0]
    address = restarted_address
    service = UPower(dict(properties, Percentage=GLib.Variant("d", 44.0)))
    expect(lambda s: s["present"] and s["text"] == "44%", "system bus reconnect restores reporting", timeout=15)
    sp.run([args.fixture, "--dispose"], env=env, check=True, timeout=5, capture_output=True)
    service.close()
    service = None
    bus.terminate()
    bus.wait(timeout=5)
    expect(lambda s: not s["visible"], "clear state before testing cold-start activation", timeout=12)
    bus, address = start_bus(activate=True)
    expect(lambda s: s["visible"] and s["text"] == "72%" and s["duration"] == "2∶30",
           "a fresh bus must activate UPower without a cable event", timeout=15)
    process.send_signal(signal.SIGTERM)
    assert process.wait(timeout=5) == 0, (root / "fixture.log").read_text()
    print("PASS battery properties, live widgets, charge limits, invalidation, invalid values, service/bus restarts, cold-start activation, and cancellation", flush=True)
finally:
    if service:
        service.close()
    if process and process.poll() is None:
        process.terminate()
        process.wait(timeout=5)
    if bus.poll() is None:
        bus.terminate()
        bus.wait(timeout=5)
    loop.quit()
