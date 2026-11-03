"""Check command failures through a private notification service and session bus."""
import subprocess
import sys
import time

from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION)
bus.call_sync(
    "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
    "RequestName", GLib.Variant("(su)", ("org.freedesktop.Notifications", 0)),
    None, Gio.DBusCallFlags.NONE, -1, None,
)
interface = Gio.DBusNodeInfo.new_for_xml("""
<node><interface name="org.freedesktop.Notifications"><method name="Notify">
<arg type="s" direction="in"/><arg type="u" direction="in"/>
<arg type="s" direction="in"/><arg type="s" direction="in"/>
<arg type="s" direction="in"/><arg type="as" direction="in"/>
<arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
<arg type="u" direction="out"/>
</method></interface></node>
""").interfaces[0]
messages = []


def notify(connection, sender, path, iface, method, params, invocation):
    values = params.unpack()
    assert values[3] == "Desktop command failed", values
    messages.append(values[4])
    invocation.return_value(GLib.Variant("(u)", (len(messages),)))


registration = bus.register_object("/org/freedesktop/Notifications", interface, notify)
process = subprocess.Popen([sys.argv[1]], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
deadline = time.monotonic() + 10
try:
    while process.poll() is None:
        while GLib.MainContext.default().iteration(False):
            pass
        assert time.monotonic() < deadline, "Command watcher hung"
        time.sleep(0.01)
    stdout, stderr = process.communicate(timeout=1)
    assert process.returncode == 0, stderr
    assert len(messages) == 4, (messages, stderr)
    for label in ("Nonzero command", "Signaled command", "Missing command", "Invalid command"):
        assert sum(message.startswith(label + ":") for message in messages) == 1, messages
        assert label in stderr, stderr
    assert any("7" in message and message.startswith("Nonzero command:") for message in messages), messages
    assert "Successful command" not in stderr, stderr
    print("PASS: nonzero exits, signals, spawn/parse errors notify and log; success is quiet")
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    bus.unregister_object(registration)
