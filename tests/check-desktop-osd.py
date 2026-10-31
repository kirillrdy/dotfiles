"""Headless integration test; run under dbus-run-session with labwc, grim,
wlr-randr, wtype, PipeWire, WirePlumber, and dbus-send on PATH. Audio uses private virtual devices.
For an unwrapped development binary, supply --loader-cache explicitly.
"""

import argparse
import json
import os
import re
import select
import shutil
import struct
import subprocess as sp
import sys
import tempfile
import time
import zlib
sys.dont_write_bytecode = True
from backlight_mock import BacklightMock
from audio_server import AudioServer
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True, type=Path)
parser.add_argument("--config", required=True, type=Path)
parser.add_argument("--loader-cache", type=Path)
parser.add_argument("--dbus-config", type=Path)
args = parser.parse_args()
for tool in ("desktop-zig", "grim", "wlr-randr", "wtype", "dbus-send"):
    if shutil.which(tool) is None:
        parser.error(f"Missing executable: {tool}")
root = Path(tempfile.mkdtemp(prefix="desktop-osd-check-", dir="/tmp"))
print(f"Artifacts: {root}", flush=True)
(root / "runtime").mkdir(mode=0o700)
(root / "config/labwc").mkdir(parents=True)
(root / "config/labwc/rc.xml").write_text("<labwc_config />")
(root / "config/labwc/autostart").write_text("")
(root / "config/labwc/environment").write_text("LABWC_UPDATE_ACTIVATION_ENV=false\n")
state_file = root / "state.json"
state_file.write_text(json.dumps({"brightness": 20}))
def set_brightness(percent):
    state = json.loads(state_file.read_text())
    state["brightness"] = percent
    state_file.write_text(json.dumps(state))

backlight = BacklightMock(root, args.dbus_config, on_set=set_brightness)
env = dict(os.environ)
for name in ("DISPLAY", "WAYLAND_DISPLAY", "LABWC_PID", "GDK_PIXBUF_MODULE_FILE"):
    env.pop(name, None)
env.update(
    OSD_TEST_ROOT=str(root),
    DESKTOP_BACKLIGHT_FIXTURE_ROOT=str(backlight.sysfs),
    DBUS_SYSTEM_BUS_ADDRESS=backlight.address,
    XDG_RUNTIME_DIR=str(root / "runtime"),
    XDG_CONFIG_HOME=str(root / "config"),
    XDG_DATA_DIRS=env.get("XDG_DATA_DIRS", "/run/current-system/sw/share"),
    XDG_CACHE_HOME=str(root / "cache"),
    WLR_BACKENDS="headless",
    WLR_RENDERER="pixman",
    WLR_HEADLESS_OUTPUTS="2",
    LABWC_UPDATE_ACTIVATION_ENV="false",
    NO_AT_BRIDGE="1",
    GIO_USE_VFS="local",
    GTK_USE_PORTAL="0",
    DESKTOP_OSD_SOUND_FILE=str(root / "feedback.oga"),
)
if args.loader_cache:
    env["GDK_PIXBUF_MODULE_FILE"] = str(args.loader_cache)
processes = []
audio = AudioServer(root, env)


def start(command, filename, extra=None):
    with (root / filename).open("w") as output:
        process = sp.Popen(
            command, env=env | (extra or {}), stdout=output, stderr=sp.STDOUT
        )
    processes.append(process)
    return process


def run(command, check=True):
    return sp.run(
        command, env=env, check=check, capture_output=True, text=True, timeout=8
    )


def send(*command):
    run([str(args.binary), *command])


def wait_for(predicate, seconds=6):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.03)
    raise AssertionError(
        "Timed out waiting for state; " + (root / "osd.log").read_text()[-3000:]
    )


def state():
    return json.loads(state_file.read_text()) | audio.state()


def pixels(name, output="HEADLESS-1"):
    path = root / (name + ".png")
    run(["grim", "-o", output, str(path)])
    data = path.read_bytes()
    chunks = []
    position = 8
    while position < len(data):
        length = struct.unpack_from(">I", data, position)[0]
        if data[position + 4 : position + 8] == b"IDAT":
            chunks.append(data[position + 8 : position + 8 + length])
        position += length + 12
    return zlib.decompress(b"".join(chunks))


def log():
    return (root / "osd.log").read_text()


def pointer_command(command):
    pointer.stdin.write(command + "\n")
    pointer.stdin.flush()
    assert select.select([pointer.stdout], [], [], 3)[0], "pointer timed out"
    assert pointer.stdout.readline() == "ok\n"


try:
    audio.start()
    audio.command("set-volume", "@DEFAULT_AUDIO_SINK@", "0.5")
    audio.command("set-mute", "@DEFAULT_AUDIO_SINK@", "1")
    audio.command("set-mute", "@DEFAULT_AUDIO_SOURCE@", "0")
    compositor = start(["desktop-zig", "compositor-only"], "labwc.log")
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
    # A missing daemon must fail without touching any hardware backend.
    assert run([str(args.binary), "volume", "up"], check=False).returncode != 0
    assert not (root / "calls.log").exists()
    bad_config = root / "invalid-osd.json"
    bad_config.write_text('{"width": 0}')
    assert run([str(args.binary), "serve", str(bad_config)], check=False).returncode != 0
    with (root / "pointer.log").open("w") as output:
        pointer = sp.Popen([str(args.binary.parent / "desktop-pointer-fixture")], env=env,
                           stdin=sp.PIPE, stdout=sp.PIPE, stderr=output, text=True)
    processes.append(pointer)
    assert select.select([pointer.stdout], [], [], 3)[0], "pointer startup timed out"
    assert pointer.stdout.readline() == "ready\n"
    # The fixture normalizes pointer coordinates to 1728x1080; the real layout
    # includes the second output, so account for its extra width.
    pointer_command(f"move {864 * 1728 // 3008} 991")
    start(["wtype", "-s", "55000"], "keyboard.log")
    start(
        [
            str(args.binary.parent / "labwc-switcher-fixture"),
            "org.dotfiles.OsdFocusFixture",
            "OSD focus fixture",
        ],
        "focus.log",
        {"DESKTOP_FIXTURE_MAXIMIZED": "1", "DESKTOP_FIXTURE_CLICKS": "1"},
    )
    wait_for(lambda: "OSD focus fixture" in (root / "focus.log").read_text())
    time.sleep(0.2)
    server = start(
        [str(args.binary), "serve", str(args.config)],
        "osd.log",
        {"G_DEBUG": "fatal-criticals", "WAYLAND_DEBUG": "1", "GDK_BACKEND": "invalid-native-osd-test"},
    )

    def registered():
        result = run(
            [
                "dbus-send",
                "--session",
                "--print-reply",
                "--dest=org.freedesktop.DBus",
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus.NameHasOwner",
                "string:org.dotfiles.DesktopOsd",
            ]
        )
        return "boolean true" in result.stdout

    wait_for(registered)
    time.sleep(0.4)
    baseline = pixels("hidden")
    baseline_second = pixels("hidden-second", "HEADLESS-2")
    send("volume", "up")
    wait_for(lambda: state()["volume"] == 55 and not state()["muted"])
    time.sleep(0.2)
    assert pixels("volume") != baseline
    assert pixels("volume-second", "HEADLESS-2") != baseline_second
    assert log().count('"desktop-osd")') == 2
    assert "set_exclusive_zone(-1)" in log()
    assert "set_keyboard_interactivity(0)" in log()
    assert "set_input_region(wl_region" in log()
    assert "set_margin(0, 0, 64, 0)" in log(), "incorrect output-relative placement"
    assert "create_buffer" in log() and re.search(r"create_buffer\(.*240, 50, 960, 0\)", log()), "OSD buffer must have alpha"
    assert not re.search(r"wl_keyboard#\d+\.enter\(", log()), "OSD stole keyboard focus"
    # Refresh pointer focus after the application maps and the OSD appears.
    pointer_command(f"move {864 * 1728 // 3008} 991")
    pointer_command("button 1")
    pointer_command("button 0")
    wait_for(lambda: "clicked" in (root / "focus.log").read_text())
    commits = log().count(".attach(")
    time.sleep(0.1)
    assert log().count(".attach(") == commits, "OSD repaints while idle"
    print(
        "PASS unmute, volume step, two native overlays, alpha, placement, idle rendering and click-through", flush=True
    )
    # Each command is accepted through the one daemon even when keys repeat rapidly.
    clients = [
        sp.Popen(
            [str(args.binary), "volume", "up"],
            env=env,
            stdout=sp.DEVNULL,
            stderr=sp.DEVNULL,
        )
        for _ in range(25)
    ]
    for client in clients:
        assert client.wait(timeout=8) == 0
    wait_for(lambda: state()["volume"] == 100)
    time.sleep(0.3)
    clients = [
        sp.Popen(
            [str(args.binary), "volume", "down"],
            env=env,
            stdout=sp.DEVNULL,
            stderr=sp.DEVNULL,
        )
        for _ in range(12)
    ]
    for client in clients:
        assert client.wait(timeout=8) == 0
    wait_for(lambda: state()["volume"] == 40)
    send("volume", "mute")
    wait_for(lambda: state()["muted"])
    time.sleep(0.15)
    pixels("muted")
    send("microphone", "mute")
    wait_for(lambda: state()["mic_muted"])
    time.sleep(0.15)
    pixels("microphone")
    print(
        "PASS key repeat, 100 percent cap and native mute toggles",
        flush=True,
    )
    for _ in range(8):
        send("brightness", "down")
    wait_for(lambda: state()["brightness"] == 5)
    time.sleep(0.2)
    pixels("brightness-floor")
    for _ in range(22):
        send("brightness", "up")
    wait_for(lambda: state()["brightness"] == 100)
    time.sleep(0.2)
    pixels("brightness-ceiling")
    time.sleep(1.6)
    assert pixels("dismissed") == baseline, "OSD did not disappear"
    print("PASS brightness limits and automatic dismissal", flush=True)
    # A stopped server must time out without blocking brightness work behind it.
    audio.suspend()
    send("volume", "down")
    send("brightness", "down")
    wait_for(lambda: state()["brightness"] == 95)
    audio.resume()
    time.sleep(.2)
    audio.stop()
    time.sleep(.2)
    send("volume", "down")
    send("brightness", "down")
    wait_for(lambda: state()["brightness"] == 90)
    print("PASS native audio timeout, disconnect and queue recovery", flush=True)
    before_scale = len(log())
    run(
        [
            "wlr-randr",
            "--output",
            "HEADLESS-1",
            "--custom-mode",
            "2808x1950",
            "--scale",
            "1.625",
        ]
    )
    run(["wlr-randr", "--output", "HEADLESS-2", "--off"])
    time.sleep(0.2)
    run(["wlr-randr", "--output", "HEADLESS-2", "--on"])
    time.sleep(0.2)
    send("brightness", "up")
    wait_for(lambda: state()["brightness"] == 95)
    time.sleep(0.2)
    pixels("fractional-scale")
    pixels("reenabled-output", "HEADLESS-2")
    assert "set_buffer_scale(2)" in log()
    assert "set_margin(0, 0, 72, 0)" in log()[before_scale:], "incorrect margin for 1200 logical pixels at fractional scale"
    assert server.poll() is None
    assert not re.search(r"CRITICAL|panic:|assertion", log()), log()[-3000:]
    # GTK/font diagnostics share this log; only timestamped records are focus events.
    focus_events = re.findall(r"^\d+ OSD focus fixture$", (root / "focus.log").read_text(), re.MULTILINE)
    assert len(focus_events) == 1, ("Application focus changed", focus_events)
    assert not re.search(r"wl_keyboard#\d+\.enter\(", log()), "OSD stole keyboard focus"
    print("PASS fractional scale and output disable/reenable", flush=True)
    server.terminate()
    assert server.wait(timeout=5) == 0
    print("PASS clean shutdown", flush=True)
finally:
    audio.stop()
    backlight.stop()
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except sp.TimeoutExpired:
                process.kill()
                process.wait()
