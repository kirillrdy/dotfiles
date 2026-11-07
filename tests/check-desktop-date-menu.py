"""Real pointer/keyboard tests for the native date popup on a private display/bus."""
import json
import os
from pathlib import Path
import select
import struct
import subprocess as sp
import sys
import tempfile
import time
import zlib
from gi.repository import Gio, GLib

bin_dir = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix="desktop-date-menu-check-", dir="/tmp"))
print(f"Date menu artifacts: {root}", flush=True)
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
name = "org.freedesktop.Notifications"
path = "/org/freedesktop/Notifications"
control = "org.dotfiles.Notifications"
signals = []
subscription = bus.signal_subscribe(None, name, None, path, None, 0,
    lambda connection, sender, object_path, iface, member, params: signals.append((member, params.unpack())))


def pump():
    while GLib.MainContext.default().iteration(False):
        pass


def wait_for(predicate, description):
    deadline = time.monotonic() + 10
    while True:
        pump()
        if predicate():
            return
        assert service.poll() is None, log.read_text()[-8000:]
        assert time.monotonic() < deadline, description
        time.sleep(.05)


def call(member, parameters=None, iface=control):
    return bus.call_sync(name, path, iface, member, parameters, None, 0, 5000, None).unpack()


def notify(body="Body", actions=(), resident=False, replace=0):
    hints = {"urgency": GLib.Variant("y", 1), "resident": GLib.Variant("b", resident)}
    return call("Notify", GLib.Variant("(susssasa{sv}i)", (
        "Messages 東京", replace, "application-x-executable-symbolic", "مرحبا <&>", body, list(actions), hints, 0)), name)[0]


def history():
    return json.loads(call("List")[0])


def pointer_command(command):
    pointer.stdin.write(command + "\n")
    pointer.stdin.flush()
    assert select.select([pointer.stdout], [], [], 5)[0], "Virtual pointer hung"
    assert pointer.stdout.readline().strip() == "ok"
    time.sleep(.07)


def move(x, y):
    pointer_command(f"move {int(x)} {int(y)}")


def click(x, y):
    move(left + x, top + y)
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


def popup_origin(rows):
    separator = bytes([74, 74, 78])
    runs = {}
    for y, row in enumerate(rows):
        active = {}
        x = row.find(separator)
        while x >= 0:
            if x % 3 == 0:
                start, end = runs.get(x, (y, y - 1))
                if end != y - 1:
                    start = y
                active[x] = start, y
                if y - start >= 399:
                    return x // 3 - 444, start - 8
            x = row.find(separator, x + 3)
        runs = active
    return None


def pane(rows, x, width, y=0, height=420):
    return b"".join(row[(left + x) * 3:(left + x + width) * 3] for row in rows[top + y:top + y + height])


def card_ready():
    rows = capture("live")[2]
    return rows[top + 108][(left + 100) * 3:(left + 100) * 3 + 3] == bytes([84, 84, 90])


log = root / "service.log"
keyboard = sp.Popen(["wtype", "-s", "120000"])
time.sleep(.1)
with log.open("w") as output:
    service = sp.Popen([str(bin_dir / "desktop-notifications-fixture"), "date-menu"],
        stdout=output, stderr=sp.STDOUT, env=dict(os.environ, G_DEBUG="fatal-criticals"))
pointer = sp.Popen([str(bin_dir / "desktop-pointer-fixture")], stdin=sp.PIPE, stdout=sp.PIPE, text=True)
try:
    assert select.select([pointer.stdout], [], [], 5)[0]
    assert pointer.stdout.readline().strip() == "ready"
    wait_for(lambda: bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
        "NameHasOwner", GLib.Variant("(s)", (name,)), None, 0, 5000, None).unpack()[0], "Notification owner")
    wait_for(lambda: popup_origin(capture("opening")[2]) is not None, "Native popup mapping")
    width, height, rows = capture("empty")
    left, top = popup_origin(rows)
    pointer_command(f"size {width} {height}")
    move(0, height - 1)
    before = capture("calendar-before")[2]
    click(480, 113)
    move(0, height - 1)
    previous = capture("calendar-previous")[2]
    assert pane(before, 460, 280) != pane(previous, 460, 280), "Previous month did not redraw"
    click(600, 40)
    click(480, 191)
    move(0, height - 1)
    selected = capture("calendar-selected")[2]
    sp.run(["wtype", "-k", "Right"], check=True, timeout=5)
    wait_for(lambda: pane(selected, 460, 280) != pane(capture("calendar-keyboard")[2], 460, 280), "Keyboard date selection did not redraw")

    identifier = notify("<b>Long body</b> &amp; 東京 " * 20,
        ("default", "Open", "reply", "Reply", "archive", "Archive"), resident=True)
    wait_for(card_ready, "History notification rendering")
    click(366, 40)
    move(0, height - 1)
    expanded = capture("expanded")[2]
    card_color = bytes([84, 84, 90])
    bottom = max(y - top for y, row in enumerate(expanded[top:top + 360], top)
        if row[(left + 20) * 3:(left + 420) * 3].count(card_color) > 100)
    assert bottom > 200, bottom
    click(60, bottom - 26)
    wait_for(lambda: ("ActionInvoked", (identifier, "reply")) in signals, "Named history action")
    assert len(history()) == 1, "Resident action must retain the notification"
    notify("Replacement <invalid markup", ("default", "Open", "reply", "Reply"), resident=True, replace=identifier)
    time.sleep(.2)
    replaced = capture("replacement")[2]
    assert any(row[(left + 40) * 3:(left + 400) * 3].count(card_color) > 100
        for row in replaced[top + 140:top + 155]), "Replacement lost expansion"
    click(180, 90)
    wait_for(lambda: ("ActionInvoked", (identifier, "default")) in signals, "Default history action")
    move(left + 400, top + 40)
    pointer_command("button 1")
    move(left + 440, top + 40)
    pointer_command("button 0")
    assert len(history()) == 1, "Dragging away from Close must cancel dismissal"
    click(400, 40)
    wait_for(lambda: not history(), "History dismissal")

    for i in range(8):
        notify(f"History item {i}")
    wait_for(card_ready, "History burst rendering")
    time.sleep(.2)
    click(160, 90)
    # Default activation removes this non-resident item and preserves focus by ID.
    wait_for(lambda: len(history()) == 7, "Non-resident history activation")
    time.sleep(.2)
    move(0, height - 1)
    unscrolled = capture("history-top")[2]
    move(left + 436, top + 30)
    pointer_command("button 1")
    move(left + 436, top + 352)
    pointer_command("button 0")
    wait_for(lambda: pane(unscrolled, 8, 424, 8, 352) != pane(capture("history-dragged")[2], 8, 424, 8, 352), "History scrollbar drag")
    dragged = capture("history-dragged")[2]
    sp.run(["wtype", "-k", "Page_Up"], check=True, timeout=5)
    wait_for(lambda: pane(dragged, 8, 424, 8, 352) != pane(capture("history-paged-up")[2], 8, 424, 8, 352), "History keyboard paging")
    sp.run(["wtype", "-k", "Page_Down"], check=True, timeout=5)
    wait_for(lambda: pane(unscrolled, 8, 424, 8, 352) != pane(capture("history-scrolled")[2], 8, 424, 8, 352), "History did not scroll")
    scrolled = capture("history-scrolled")[2]
    assert pane(unscrolled, 460, 280) == pane(scrolled, 460, 280), "History scrolling changed calendar pixels"
    click(55, 390)
    wait_for(lambda: not history(), "Clear notification history")
    time.sleep(.15)
    capture("cleared")
    sp.run(["wtype", "-k", "Escape"], check=True, timeout=5)
    wait_for(lambda: popup_origin(capture("hidden")[2]) is None, "Calendar dismissal")
    notify("Banner after calendar closed")
    wait_for(lambda: any(row.count(card_color) > 100 for row in capture("after-close")[2][:118]), "Closing calendar must restore banners")
    print("PASS: native date popup navigation, keyboard, history expansion/actions/replacement, dismissal, scrolling, Clear and calendar suppression")
finally:
    bus.signal_unsubscribe(subscription)
    pointer.stdin.close()
    pointer.wait(timeout=5)
    keyboard.terminate()
    keyboard.wait(timeout=5)
    service.terminate()
    try:
        service.wait(timeout=5)
    except sp.TimeoutExpired:
        service.kill()
        service.wait()
