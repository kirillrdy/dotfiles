"""Private logind service and sysfs backlight tree for native brightness tests."""
import os
from pathlib import Path
import subprocess as sp
import threading
from gi.repository import Gio, GLib


class BacklightMock:
    def __init__(self, root, config=None, on_set=None):
        self.root = Path(root)
        self.sysfs = self.root / "backlight"
        self.sysfs.mkdir()
        self.device("intel", 80, 400, "raw")
        self.calls = []
        self.deny = False
        self.delay = 0
        self.on_set = on_set
        self.loop = GLib.MainLoop()
        self.thread = threading.Thread(target=self.loop.run, daemon=True)
        self.thread.start()
        self.log = (self.root / "backlight-bus.log").open("w")
        command = ["dbus-daemon", "--nofork", "--print-address=1",
                   "--config-file=" + str(config) if config else "--session"]
        self.bus = sp.Popen(command, stdout=sp.PIPE, stderr=self.log, text=True)
        self.address = self.bus.stdout.readline().strip()
        if not self.address.startswith("unix:"):
            raise RuntimeError((self.root / "backlight-bus.log").read_text())
        self.conn = Gio.DBusConnection.new_for_address_sync(self.address,
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None, None)
        self.conn.set_exit_on_close(False)
        xml = '''<node><interface name="org.freedesktop.login1.Session"><method name="SetBrightness">
        <arg type="s" direction="in"/><arg type="s" direction="in"/>
        <arg type="u" direction="in"/></method></interface></node>'''
        self.registration = self.conn.register_object("/org/freedesktop/login1/session/auto",
            Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], self.method, None, None)
        self.conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "RequestName", GLib.Variant("(su)", ("org.freedesktop.login1", 0)), None, 0, 3000, None)

    def device(self, name, current, maximum, kind):
        directory = self.sysfs / name
        directory.mkdir(exist_ok=True)
        for attribute, value in (("brightness", current), ("max_brightness", maximum), ("type", kind)):
            (directory / attribute).write_text(str(value) + "\n")

    def method(self, conn, sender, path, interface, method, parameters, invocation):
        subsystem, name, value = parameters.unpack()
        self.calls.append((subsystem, name, value))
        def finish():
            if self.deny:
                invocation.return_dbus_error("org.freedesktop.DBus.Error.AccessDenied", "Fixture: inactive session")
                return False
            device = self.sysfs / name
            if subsystem != "backlight" or "/" in name or not device.exists():
                invocation.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "Missing backlight")
                return False
            maximum = int((device / "max_brightness").read_text())
            assert 1 <= value <= maximum
            (device / "brightness").write_text(str(value) + "\n")
            if self.on_set:
                self.on_set(value / maximum * 100)
            invocation.return_value(GLib.Variant("()", ()))
            return False
        if self.delay:
            GLib.timeout_add(self.delay, finish)
        else:
            finish()

    def stop(self):
        self.conn.close_sync(None)
        self.bus.terminate()
        self.bus.wait(timeout=5)
        self.loop.quit()
        self.thread.join(timeout=3)
        self.log.close()
