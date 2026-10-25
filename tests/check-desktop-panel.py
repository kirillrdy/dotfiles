"""Exercise desktop-panel in an isolated headless Labwc session.

Run under dbus-run-session. Requires labwc, wlr-randr, wlrctl, wtype, grim,
and the normal desktop data-provider dependencies on PATH. Screenshots and logs
are retained in a temporary directory printed at startup.
"""

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess as sp
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
parser.add_argument("--style", required=True, type=Path, help="Panel stylesheet")
args = parser.parse_args()
args.bin = args.bin.resolve()
args.style = args.style.resolve()
for tool in ("labwc", "wlr-randr", "wlrctl", "wtype", "grim"):
    if shutil.which(tool) is None:
        parser.error(f"Missing executable: {tool}")
root = Path(tempfile.mkdtemp(prefix="desktop-panel-check-"))
print(f"Artifacts: {root}", flush=True)
(root / "runtime").mkdir(exist_ok=True)
(root / "runtime").chmod(0o700)
(root / "config/labwc").mkdir(parents=True, exist_ok=True)
(root / "config/labwc/rc.xml").write_text(
    '<labwc_config><keyboard><default /></keyboard><windowRules><windowRule identifier="*" type="normal"><action name="Maximize" /></windowRule></windowRules></labwc_config>'
)
(root / "config/labwc/autostart").write_text("")
(root / "config/labwc/environment").write_text("LABWC_UPDATE_ACTIVATION_ENV=false\n")
env = dict(os.environ)
for key in ("DISPLAY", "WAYLAND_DISPLAY", "LABWC_PID"):
    env.pop(key, None)
env.update(
    XDG_RUNTIME_DIR=str(root / "runtime"),
    XDG_CONFIG_HOME=str(root / "config"),
    XDG_CACHE_HOME=str(root / "cache"),
    XDG_DATA_DIRS="/run/current-system/sw/share",
    WLR_BACKENDS="headless",
    WLR_RENDERER="pixman",
    WLR_HEADLESS_OUTPUTS="2",
    LABWC_UPDATE_ACTIVATION_ENV="false",
    NO_AT_BRIDGE="1",
    GTK_USE_PORTAL="0",
    GIO_USE_VFS="local",
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


def pointer(x, y):
    run([wlrctl, "pointer", "move", "-10000", "-10000"])
    run([wlrctl, "pointer", "move", str(x), str(y)])


def click(x, y):
    pointer(x, y)
    run([wlrctl, "pointer", "click", "left"])
    time.sleep(0.4)


def capture(name, output="HEADLESS-1"):
    run(["grim", "-o", output, str(root / (name + ".png"))])


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


wlrctl = "wlrctl"
wtype = "wtype"
try:
    compositor = start(["labwc", "-C", str(root / "config/labwc"), "-d"], "labwc.log")
    for _ in range(100):
        if (root / "runtime/wayland-0").exists():
            break
        assert compositor.poll() is None, (root / "labwc.log").read_text()
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
    seat = start([wtype, "-s", "55000"], "seat.log")
    config = json.loads(args.config.read_text())
    for module in config["right"]:
        if module["name"] in ("gnome-monitors", "gnome-disk", "gnome-status"):
            kind = module["name"].removeprefix("gnome-")
            module["exec"] = shlex.join([str(args.bin / "waybar-panel"), kind])
    # Verify command launching without opening another app.
    config["left"][0]["on_click"] = shlex.join(
        ["touch", str(root / "activities-clicked")]
    )
    sample = {
        "items": [{"text": "54%"}],
        "tooltip": "5h: 54% remaining",
        "windows": [
            {"percent": 54, "reset": "Resets in 2h"},
            {"percent": 93, "reset": "Resets in 4d"},
        ],
        "checked": "Checked: test",
    }
    (root / "codex.json").write_text(json.dumps(sample) + "\n")
    config["right"][0]["exec"] = (
        'sh -c "cat ' + str(root / "codex.json") + '; sleep 120"'
    )
    (root / "panel.json").write_text(json.dumps(config))
    panel = start(
        [str(args.bin / "desktop-panel"), str(root / "panel.json"), str(args.style)],
        "panel.log",
        {"WAYLAND_DEBUG": "1", "G_DEBUG": "fatal-criticals"},
    )
    time.sleep(2)
    check()
    assert log().count('"desktop-panel")') == 2, (
        "Expected one layer surface per monitor"
    )
    assert "set_exclusive_zone(32)" in log(), "Panel must reserve 32 logical pixels"
    capture("panel")
    capture("second-monitor", "HEADLESS-2")
    click(35, 16)
    assert (root / "activities-clicked").exists(), "Activities command did not execute"
    print("PASS two monitors, reserved space, activities command", flush=True)
    click(864, 16)
    capture("calendar")
    assert "get_subsurface" in log(), "Calendar surface was not created"
    dismiss()
    capture("calendar-dismissed")
    before = log().count("get_subsurface")
    click(1125, 16)
    capture("codex")
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
