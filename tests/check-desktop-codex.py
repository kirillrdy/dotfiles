"""Drive the production Codex panel popup on an isolated display and bus."""
import json
import math
import os
from pathlib import Path
import subprocess as sp
import sys
import tempfile
import time
sys.dont_write_bytecode = True
from session_fixture import VirtualPointer, read_png, wait_until
from wayland_ui import VirtualKeyboard

bin_dir = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix="desktop-codex-check-", dir="/tmp"))
print(f"Codex artifacts: {root}", flush=True)
(root / "wallpaper.ppm").write_bytes(b"P6\n2 2\n255\n" + bytes([20, 40, 80]) * 4)
(root / "panel.json").write_text(json.dumps({
    "left": [], "center": [],
    "right": [{"name": "gnome-codex", "source": "codex"}],
}))
env = dict(os.environ, WB_PANEL_DEMO="1", GSETTINGS_BACKEND="memory",
           XDG_CACHE_HOME=str(root / "cache"), XDG_CONFIG_HOME=str(root / "config"),
           XDG_STATE_HOME=str(root / "state"), G_DEBUG="fatal-criticals",
           DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-system-bus"))
log = root / "shell.log"


def run(*args):
    return sp.run(args, env=env, capture_output=True, text=True, check=True, timeout=10)


def capture():
    filename = root / "screen.png"
    run(str(bin_dir / "desktop-zig"), "screenshot", "-o", "HEADLESS-1", str(filename))
    return read_png(filename)


def visible():
    # Only the Codex card uses this background in the minimal panel session.
    return any(row.count(bytes([54, 54, 58])) > 60 for row in capture()[2])


def at_scale(scale):
    width, height, rows = capture()
    zoom = min(1, (width / scale - 16) / 340, (height / scale - 16) / 280)
    left = math.floor(width / scale - 340 * zoom - 8) * scale
    top = math.floor(min(32, max(8, height / scale - 280 * zoom - 8))) * scale
    y = int(top + 80 * zoom * scale)
    x = int(left + 10 * zoom * scale)
    outside = int(left - 20 * scale)
    return (rows[y][x * 3:x * 3 + 3] == bytes([54, 54, 58]) and
            rows[y][outside * 3:outside * 3 + 3] == bytes([20, 40, 80]))


def wait_for(predicate, description):
    def alive():
        assert shell.poll() is None, log.read_text()[-8000:]
    wait_until(predicate, description, timeout=10, interval=.05, on_error=alive)


run(str(bin_dir / "desktop-zig"), "output", "--output", "HEADLESS-1", "--scale", "1")
keyboard = VirtualKeyboard(env)
pointer = VirtualPointer(bin_dir / "desktop-pointer-fixture", env=env, delay=.07)
with log.open("w") as output:
    shell = sp.Popen([str(bin_dir / "desktop-zig"), "serve", str(root / "wallpaper.ppm"),
                      str(root / "panel.json")], env=env, stdout=output, stderr=sp.STDOUT)
try:
    wait_for(lambda: sp.run([str(bin_dir / "desktop-zig"), "ping"], env=env,
                           capture_output=True).returncode == 0, "Codex shell ready")
    # Wait for the demo collector to populate the panel label.
    wait_for(lambda: any(row.count(bytes([255, 255, 255])) > 2 for row in capture()[2][:32]),
             "Codex panel label")
    width, height, _ = capture()
    pointer.command(f"size {width} {height}")
    pointer.click(width - 30, 16)
    wait_for(visible, "native Codex popup")
    # The right-edge anchor clamps the 340-pixel card inside the output.
    pointer.click(width - 348 + 70, 32 + 242)
    assert visible(), "refresh closed the popup"
    keyboard.key(1, 0)  # Escape
    wait_for(lambda: not visible(), "keyboard dismissal")
    pointer.click(width - 30, 16)
    wait_for(visible, "stationary reopening")
    keyboard.key(15, 0)  # Tab
    keyboard.key(28, 0)  # Enter refresh
    assert visible(), "keyboard refresh closed the popup"
    pointer.click(width - 30, 16)
    wait_for(lambda: not visible(), "outside dismissal over the panel")
    pointer.click(width - 30, 16)
    wait_for(visible, "reopening after outside dismissal")
    # Resize an open popup, including a tiny logical output requiring zoom.
    for scale in (2, 4, 1):
        run(str(bin_dir / "desktop-zig"), "output", "--output", "HEADLESS-1", "--scale", str(scale))
        wait_for(lambda: at_scale(scale), f"popup geometry at scale {scale}")
    pointer.click(1, height - 1)
    wait_for(lambda: not visible(), "outside dismissal after scaling")
    pointer.click(width - 30, 16)
    wait_for(visible, "popup before output removal")
    run("wlr-randr", "--output", "HEADLESS-1", "--off")
    time.sleep(.15)
    run("wlr-randr", "--output", "HEADLESS-1", "--on")
    wait_for(lambda: not visible(), "popup revoked with its output")
    wait_for(lambda: any(row.count(bytes([255, 255, 255])) > 2 for row in capture()[2][:32]),
             "replacement panel")
    pointer.click(width - 30, 16)
    wait_for(visible, "popup on replacement output")
    # Teardown while the popup owns keyboard focus must release its client.
    shell.terminate()
    assert shell.wait(timeout=10) == 0, log.read_text()[-8000:]
    assert not any(text in log.read_text() for text in ("CRITICAL", "panic:", "Segmentation")), log.read_text()[-8000:]
    print("PASS native Codex refresh, keyboard, reopening, outside dismissal, scaling, output removal and teardown")
finally:
    if shell.poll() is None:
        shell.terminate()
        shell.wait(timeout=10)
    pointer.close()
    keyboard.socket.close()
    run("wlr-randr", "--output", "HEADLESS-1", "--on", "--scale", "1")
