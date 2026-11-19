"""Real pointer/keyboard tests for the native date popup on a private display/bus."""
import json
import os
from pathlib import Path
import subprocess as sp
import sys
import tempfile
import time
sys.dont_write_bytecode = True
from gi.repository import GLib
from session_fixture import NotificationsClient, VirtualPointer, read_png, terminate_processes, wait_until, write_wallpaper

bin_dir = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix="desktop-date-menu-check-", dir="/tmp"))
print(f"Date menu artifacts: {root}", flush=True)
client = NotificationsClient()
bus, name, control, signals = client.bus, client.name, client.control, client.signals
call, history = client.call, client.history


def wait_for(predicate, description):
    def check_service():
        assert service.poll() is None, log.read_text()[-8000:]
    wait_until(predicate, description, timeout=10, interval=0.05, step=client.pump, on_error=check_service)


def notify(body="Body", actions=(), resident=False, replace=0):
    hints = {"urgency": GLib.Variant("y", 1), "resident": GLib.Variant("b", resident)}
    return call("Notify", GLib.Variant("(susssasa{sv}i)", (
        "Messages 東京", replace, "application-x-executable-symbolic", "مرحبا <&>", body, list(actions), hints, 0)), name)[0]


def pointer_command(command):
    pointer.command(command)


def move(x, y):
    pointer.move(x, y)


def click(x, y):
    pointer.click(left + x, top + y)


def capture(label):
    filename = root / (label + ".png")
    sp.run([str(bin_dir / "desktop-zig"), "screenshot", "-o", "HEADLESS-1", str(filename)], check=True, timeout=10)
    return read_png(filename)


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


write_wallpaper(root / "wallpaper.png")
(root / "panel.json").write_text(json.dumps({
    "left": [], "center": [{"kind": "clock"}], "right": [],
}))
env = dict(os.environ, G_DEBUG="fatal-criticals", WB_PANEL_DEMO="1",
           GSETTINGS_BACKEND="memory", XDG_CONFIG_HOME=str(root / "config"),
           XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"),
           DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-system-bus"))
log = root / "service.log"
keyboard = sp.Popen(["wtype", "-s", "120000"])
time.sleep(.1)
with log.open("w") as output:
    service = sp.Popen([str(bin_dir / "desktop-zig"), "serve", str(root / "wallpaper.png"),
                        str(root / "panel.json")], stdout=output, stderr=sp.STDOUT, env=env)
pointer = VirtualPointer(bin_dir / "desktop-pointer-fixture", delay=0.07)
try:
    wait_for(client.owned, "Notification owner")
    width, height, _ = capture("panel")
    pointer_command(f"size {width} {height}")
    pointer.click(width // 2, 8)
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
    card_color = bytes([84, 84, 90])
    def card_bottom():
        rows = capture("expanded")[2]
        return max(y - top for y, row in enumerate(rows[top:top + 360], top)
            if row[(left + 20) * 3:(left + 420) * 3].count(card_color) > 100)
    wait_for(lambda: card_bottom() > 200, "Expanded history card frame")
    bottom = card_bottom()
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
    # Reopen through the production clock above the popup.
    clock_x, clock_y = width // 2, 8
    pointer.click(clock_x, clock_y)
    wait_for(lambda: popup_origin(capture("reopened")[2]) is not None, "Calendar reopening")
    # Keep the pointer over the clock while its covering layer disappears.
    # A subsequent click must reach the clock without any intervening motion.
    for attempt in range(3):
        move(clock_x, clock_y)
        sp.run(["wtype", "-k", "Escape"], check=True, timeout=5)
        wait_for(lambda: popup_origin(capture("stationary-hidden")[2]) is None, "Stationary calendar dismissal")
        pointer_command("button 1")
        pointer_command("button 0")
        wait_for(lambda: popup_origin(capture("stationary-reopened")[2]) is not None,
            f"Calendar reopening without pointer motion ({attempt})")
    # Also toggle by clicking the clock itself, without moving between clicks.
    for attempt in range(3):
        pointer_command("button 1")
        pointer_command("button 0")
        wait_for(lambda: popup_origin(capture("clock-hidden")[2]) is None, "Clock-click dismissal")
        pointer_command("button 1")
        pointer_command("button 0")
        wait_for(lambda: popup_origin(capture("clock-reopened")[2]) is not None,
            f"Stationary clock toggle ({attempt})")
    pointer.click(0, height - 1)
    wait_for(lambda: popup_origin(capture("outside-dismissed")[2]) is None, "Outside-click dismissal")
    notify("Banner after calendar closed")
    wait_for(lambda: any(row.count(card_color) > 100 for row in capture("after-close")[2][:118]), "Closing calendar must restore banners")
    print("PASS: native date popup navigation, keyboard, history expansion/actions/replacement, dismissal, scrolling, Clear, stationary reopening/toggling, outside dismissal and calendar suppression")
finally:
    client.close()
    pointer.close()
    terminate_processes([keyboard, service])
