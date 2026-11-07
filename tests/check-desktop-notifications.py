"""Exercise native notification pixels and input on a private bus/headless compositor."""
import json
import os
from pathlib import Path
import re
import select
import struct
import subprocess as sp
import sys
import tempfile
import time
import zlib

from gi.repository import Gio, GLib

bin_dir = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix="desktop-notifications-check-", dir="/tmp"))
print(f"Notification artifacts: {root}", flush=True)
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
name = "org.freedesktop.Notifications"
path = "/org/freedesktop/Notifications"
control = "org.dotfiles.Notifications"
signals = []
subscription = bus.signal_subscribe(
    None, name, None, path, None, Gio.DBusSignalFlags.NONE,
    lambda connection, sender, object_path, iface, member, params: signals.append((member, params.unpack())),
)


def pump():
    while GLib.MainContext.default().iteration(False):
        pass


def wait_for(predicate, description, seconds=8):
    deadline = time.monotonic() + seconds
    while True:
        pump()
        if predicate():
            return
        assert service.poll() is None, log.read_text()[-8000:]
        assert time.monotonic() < deadline, description
        time.sleep(0.02)


def call(member, parameters=None, iface=name):
    return bus.call_sync(name, path, iface, member, parameters, None, Gio.DBusCallFlags.NONE, 5000, None).unpack()


def notify(body="Notification body", actions=(), critical=True, resident=False, transient=False, replace=0, image=False):
    hints = {"urgency": GLib.Variant("y", 2 if critical else 1),
             "resident": GLib.Variant("b", resident), "transient": GLib.Variant("b", transient)}
    if image:
        hints["image-data"] = GLib.Variant("(iiibiiay)", (2, 1, 8, True, 8, 4, bytes([255, 0, 0, 255, 0, 0, 255, 255])))
    return call("Notify", GLib.Variant("(susssasa{sv}i)", (
        "Messages", replace, "application-x-executable-symbolic", "東京 — مرحبا", body, list(actions), hints, -1)))[0]


def history():
    return json.loads(call("List", iface=control)[0])


def clear():
    call("Clear", iface=control)
    time.sleep(0.1)


def pointer_command(command):
    pointer.stdin.write(command + "\n")
    pointer.stdin.flush()
    assert select.select([pointer.stdout], [], [], 5)[0], "Virtual pointer hung"
    assert pointer.stdout.readline().strip() == "ok"
    time.sleep(0.07)


def move(x, y):
    pointer_command(f"move {int(x)} {int(y)}")


def click(x, y):
    move(x, y)
    pointer_command("button 1")
    pointer_command("button 0")


def capture(label):
    filename = root / (label + ".png")
    sp.run([str(bin_dir / "desktop-zig"), "screenshot", "-o", "HEADLESS-1", str(filename)], check=True, timeout=10)
    png = filename.read_bytes()
    width, height = struct.unpack_from(">II", png, 16)
    compressed = []
    offset = 8
    while offset < len(png):
        length = struct.unpack_from(">I", png, offset)[0]
        if png[offset + 4:offset + 8] == b"IDAT":
            compressed.append(png[offset + 8:offset + 8 + length])
        offset += length + 12
    raw = zlib.decompress(b"".join(compressed))
    rows = []
    stride = width * 3
    for y in range(height):
        filter_type = raw[y * (stride + 1)]
        row = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        assert filter_type in (0, 1), filter_type
        if filter_type == 1:
            for x in range(3, stride):
                row[x] = (row[x] + row[x - 3]) & 255
        rows.append(bytes(row))
    return width, height, rows


def card_bottom(rows):
    return max((y for y, row in enumerate(rows) if row.count(bytes([84, 84, 90])) > 100), default=-1)


log = root / "service.log"
with log.open("w") as output:
    service = sp.Popen([str(bin_dir / "desktop-notifications-fixture")],
                       stdout=output, stderr=sp.STDOUT, env=dict(os.environ, WAYLAND_DEBUG="client", G_DEBUG="fatal-criticals"))
pointer = sp.Popen([str(bin_dir / "desktop-pointer-fixture")], stdin=sp.PIPE, stdout=sp.PIPE, text=True)
scaled = False
try:
    assert select.select([pointer.stdout], [], [], 5)[0]
    assert pointer.stdout.readline().strip() == "ready"

    def owned():
        return bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                             "NameHasOwner", GLib.Variant("(s)", (name,)), None, Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
    wait_for(owned, "Notification name ownership")
    width, height, baseline = capture("baseline")
    pointer_command(f"size {width} {height}")
    move(0, height - 1)
    left = (width - 529) // 2

    identifier = notify("<b>Bold message</b> &amp; 東京 " * 20, ("default", "Open", "reply", "Reply", "archive", "Archive"), image=True)
    wait_for(lambda: '"desktop-notifications"' in log.read_text(), "Native notification surface")
    time.sleep(0.2)
    _, _, collapsed = capture("collapsed")
    collapsed_bottom = card_bottom(collapsed)
    assert 90 < collapsed_bottom < 130, collapsed_bottom
    assert collapsed[height // 2] == baseline[height // 2], "Banner must leave the desktop below it unchanged"
    assert any(row[x] > 200 and row[x + 1] < 30 and row[x + 2] < 60
               for row in collapsed[50:105] for x in range(0, len(row), 3)), "Raw image hint missing"
    click(left + 458, 28)
    _, _, expanded = capture("expanded")
    expanded_bottom = card_bottom(expanded)
    assert expanded_bottom > collapsed_bottom + 60, (collapsed_bottom, expanded_bottom)
    click(left + 70, expanded_bottom - 27)
    wait_for(lambda: ("ActionInvoked", (identifier, "reply")) in signals, "Action button signal")
    wait_for(lambda: ("NotificationClosed", (identifier, 2)) in signals, "Action closes notification")
    assert not history()

    # A resident default action survives; releasing a close press elsewhere cancels it.
    identifier = notify(actions=("default", "Open"), resident=True)
    time.sleep(0.15)
    click(left + 180, 65)
    wait_for(lambda: ("ActionInvoked", (identifier, "default")) in signals, "Default action")
    assert history()[0]["id"] == identifier
    move(left + 490, 28)
    pointer_command("button 1")
    move(left + 180, 65)
    pointer_command("button 0")
    assert history()[0]["id"] == identifier, "Drag out must cancel dismissal"
    assert notify("Replacement <invalid markup", replace=identifier, resident=True) == identifier
    assert history()[0]["body"] == "Replacement <invalid markup"
    time.sleep(0.15)
    capture("replacement-invalid-markup")
    click(left + 490, 28)
    wait_for(lambda: not history(), "Close button")

    # Hover cancels normal expiry; leaving restores the existing short grace period.
    identifier = notify(critical=False, transient=True)
    time.sleep(0.15)
    move(left + 180, 65)
    time.sleep(4.2)
    assert history()[0]["id"] == identifier
    assert card_bottom(capture("hovered")[2]) > 90
    move(0, height - 1)
    wait_for(lambda: ("NotificationClosed", (identifier, 1)) in signals, "Transient expiry after pointer leave")
    assert not history()
    identifier = notify(critical=False)
    time.sleep(4.3)
    assert history()[0]["id"] == identifier, "Non-transient expiry retains history"
    assert card_bottom(capture("expired-history")[2]) == -1
    clear()

    # Critical messages preempt ordinary banners and do not expire.
    notify("Ordinary queued message", critical=False)
    identifier = notify("Critical message", resident=True, actions=("default", "Open"))
    time.sleep(4.2)
    assert card_bottom(capture("critical")[2]) > 90
    click(left + 180, 65)
    wait_for(lambda: ("ActionInvoked", (identifier, "default")) in signals, "Critical preemption")
    call("CalendarOpen", GLib.Variant("(b)", (True,)), iface=control)
    time.sleep(0.1)
    assert card_bottom(capture("calendar-open")[2]) == -1
    assert len(history()) == 2
    clear()
    call("CalendarOpen", GLib.Variant("(b)", (False,)), iface=control)

    # A live scale change rebuilds physical text masks and preserves logical input.
    identifier = notify(actions=("default", "Open"), resident=True)
    time.sleep(0.15)
    sp.run([str(bin_dir / "desktop-zig"), "output", "--output", "HEADLESS-1", "--scale", "2"], check=True, timeout=10)
    scaled = True
    time.sleep(0.3)
    _, _, scaled_rows = capture("scale-2")
    assert card_bottom(scaled_rows) > 180
    pointer_command(f"size {width // 2} {height // 2}")
    click((width // 2 - 529) // 2 + 490, 28)
    wait_for(lambda: not history(), "Scaled close button")
    sp.run([str(bin_dir / "desktop-zig"), "output", "--output", "HEADLESS-1", "--scale", "1"], check=True, timeout=10)
    scaled = False
    service.terminate()
    assert service.wait(timeout=8) == 0
    assert not re.search(r"CRITICAL|assertion|panic:|Segmentation|notification .*failed", log.read_text()), log.read_text()[-8000:]
    print("PASS: native banner pixels, Unicode/markup/images, expansion, actions, replacement, resident/critical/history, hover expiry, calendar suppression and live scaling")
finally:
    bus.signal_unsubscribe(subscription)
    if scaled:
        sp.run([str(bin_dir / "desktop-zig"), "output", "--output", "HEADLESS-1", "--scale", "1"], timeout=10)
    pointer.stdin.close()
    pointer.wait(timeout=5)
    if service.poll() is None:
        service.terminate()
        service.wait(timeout=8)
