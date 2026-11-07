"""Exercise desktop-panel in an isolated headless Wayland session.

Run under dbus-run-session. Requires wlr-randr, wtype, grim, desktop-pointer-fixture,
and the normal desktop data-provider dependencies on PATH. Screenshots and logs
are retained in a temporary directory printed at startup.
"""

import argparse
import sys
sys.dont_write_bytecode = True
from session_fixture import command as session_command, wait_ready
import json
import os
import re
import shlex
import shutil
import subprocess as sp
import struct
import zlib
import tempfile
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--bin", required=True, type=Path, help="Built desktop-zig bin directory"
)
parser.add_argument(
    "--config", required=True, type=Path, help="Generated panel JSON configuration"
)
parser.add_argument("--style", type=Path, help="Panel stylesheet")
args = parser.parse_args()
args.bin = args.bin.resolve()
for tool in ("desktop-zig", "wlr-randr", "wtype", "grim"):
    if shutil.which(tool) is None:
        parser.error(f"Missing executable: {tool}")
root = Path(tempfile.mkdtemp(prefix="desktop-panel-check-"))
print(f"Artifacts: {root}", flush=True)
(root / "runtime").mkdir(exist_ok=True)
(root / "runtime").chmod(0o700)
env = dict(os.environ)
for key in ("DISPLAY", "WAYLAND_DISPLAY"):
    env.pop(key, None)
env.update(
    XDG_RUNTIME_DIR=str(root / "runtime"),
    XDG_CONFIG_HOME=str(root / "config"),
    XDG_CACHE_HOME=str(root / "cache"),
    WLR_BACKENDS="headless",
    WLR_RENDERER="pixman",
    WLR_HEADLESS_OUTPUTS="2",
    NO_AT_BRIDGE="1",
    GTK_USE_PORTAL="0",
    GIO_USE_VFS="local",
    WB_PANEL_DEMO="1",
    DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-system-bus"),
)
procs = []


def start(args, log, extra=None):
    with (root / log).open("w") as output:
        p = sp.Popen(args, env=env | (extra or {}), stdout=output, stderr=sp.STDOUT)
    procs.append(p)
    return p


def run(args):
    return sp.run(
        args, env=env, check=True, timeout=10, capture_output=True, text=True
    ).stdout


def pointer_command(command):
    pointer_process.stdin.write(command + "\n")
    pointer_process.stdin.flush()
    assert pointer_process.stdout.readline().strip() == "ok"


def pointer(x, y):
    pointer_command(f"move {x} {y}")


def click(x, y):
    pointer(x, y)
    pointer_command("button 1")
    pointer_command("button 0")
    time.sleep(0.4)


def capture(name, output="HEADLESS-1"):
    run(["grim", "-o", output, str(root / (name + ".png"))])


def check_clock():
    # A live popup can still work when the initial label was clipped away.
    path = root / "panel-clock.png"
    run([str(args.bin / "desktop-zig"), "screenshot", "-o", "HEADLESS-1", str(path)])
    png = path.read_bytes()
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
    for y in range(32):
        filter_type = raw[y * (stride + 1)]
        row = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        assert filter_type in (0, 1), filter_type
        if filter_type == 1:
            for x in range(3, stride):
                row[x] = (row[x] + row[x - 3]) & 255
        rows.append(row)
    for low, high in ((width // 2 - 128, width // 2),
                      (width // 2, width // 2 + 128)):
        bright = sum(min(rows[y][x * 3:x * 3 + 3]) > 180
                     for y in range(4, 28) for x in range(low, high))
        assert bright > 40, "Clock text missing or clipped on initial panel frame"


def log():
    return (root / "panel.log").read_text()


def dismiss():
    before = len(re.findall(r"wl_subsurface#\d+\.destroy\(\)", log()))
    run([wtype, "-k", "Escape"])
    time.sleep(0.3)
    assert len(re.findall(r"wl_subsurface#\d+\.destroy\(\)", log())) > before, (
        "Escape did not dismiss the popup"
    )


def check():
    assert panel.poll() is None, log()
    assert not re.search(r"CRITICAL|assertion|panic:|error:", log()), log()[-4000:]


wtype = "wtype"
try:
    compositor = start(["desktop-zig", "compositor-only"], "compositor.log")
    for _ in range(100):
        if (root / "runtime/wayland-0").exists():
            break
        assert compositor.poll() is None, (root / "compositor.log").read_text()
        time.sleep(0.05)
    env["WAYLAND_DISPLAY"] = "wayland-0"
    run(
        [
            "wlr-randr",
            "--output",
            "HEADLESS-1",
            "--custom-mode",
            "1728x1080",
            "--pos",
            "0,0",
            "--output",
            "HEADLESS-2",
            "--custom-mode",
            "1280x800",
            "--pos",
            "1728,0",
        ]
    )
    pointer_process = sp.Popen([args.bin / "desktop-pointer-fixture"], env=env,
                                stdin=sp.PIPE, stdout=sp.PIPE, text=True)
    procs.append(pointer_process)
    assert pointer_process.stdout.readline().strip() == "ready"
    pointer_command("size 3008 1080")
    seat = start([wtype, "-s", "55000"], "seat.log")
    config = json.loads(args.config.read_text())
    # Verify command launching without opening another app.
    config["left"][0]["on_click"] = shlex.join(
        ["touch", str(root / "activities-clicked")]
    )
    # Keep the Codex click independent of changing battery/disk label widths.
    config["left"].append(config["right"].pop(0))
    (root / "panel.json").write_text(json.dumps(config))
    panel = start(
        session_command(args.bin / "desktop-zig", root, panel_config=root / "panel.json"),
        "panel.log",
        {"WAYLAND_DEBUG": "1", "G_DEBUG": "fatal-criticals"},
    )
    wait_ready(args.bin / "desktop-zig", env, panel)
    time.sleep(2)
    check()
    assert log().count('"desktop-panel")') == 2, (
        "Expected one layer surface per monitor"
    )
    assert "set_exclusive_zone(32)" in log(), "Panel must reserve 32 logical pixels"
    capture("panel")
    check_clock()
    capture("second-monitor", "HEADLESS-2")
    click(35, 16)
    assert (root / "activities-clicked").exists(), "Activities command did not execute"
    print("PASS two monitors, reserved space, activities command", flush=True)
    click(864, 16)
    capture("calendar")
    assert "get_subsurface" in log(), "Calendar surface was not created"
    dismiss()
    capture("calendar-dismissed")
    pointer(112, 16)
    time.sleep(1.0)
    capture("codex-tooltip")
    before = log().count("get_subsurface")
    click(112, 16)
    capture("codex")
    run([wtype, "-k", "Return"])
    time.sleep(0.3)
    capture("codex-keyboard-refresh")
    assert log().count("get_subsurface") > before, "Codex popover did not open"
    dismiss()
    before = log().count("get_subsurface")
    click(1700, 16)
    capture("quick-settings")
    assert log().count("get_subsurface") > before, "Quick settings did not open"
    dismiss()
    check()
    print(
        "PASS calendar, Codex and quick settings open and Escape dismissal", flush=True
    )
    run(
        [
            "wlr-randr",
            "--output",
            "HEADLESS-1",
            "--custom-mode",
            "2808x1755",
            "--scale",
            "1.625",
            "--output",
            "HEADLESS-2",
            "--pos",
            "1728,0",
        ]
    )
    time.sleep(0.8)
    capture("fractional-scale")
    check()
    print("PASS fractional scale 1.625", flush=True)
    before = log().count('"desktop-panel")')
    run(["wlr-randr", "--output", "HEADLESS-2", "--off"])
    time.sleep(0.5)
    check()
    run(["wlr-randr", "--output", "HEADLESS-2", "--on"])
    time.sleep(0.8)
    check()
    assert log().count('"desktop-panel")') > before, (
        "No replacement panel after output reenabled"
    )
    capture("monitor-reenabled", "HEADLESS-2")
    print("PASS output disable and reenable", flush=True)
    panel.terminate()
    assert panel.wait(timeout=5) == 0, log()[-4000:]
    print("PASS clean SIGTERM shutdown", flush=True)
finally:
    for p in reversed(procs):
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except sp.TimeoutExpired:
                p.kill()
                p.wait()
