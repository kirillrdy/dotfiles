"""Headless integration test; run under dbus-run-session with labwc, grim,
wlr-randr, wtype, and dbus-send on PATH. All hardware backends are replaced by mocks.
For an unwrapped development binary, supply --loader-cache explicitly.
"""

import argparse
import json
import os
import re
import shutil
import struct
import subprocess as sp
import sys
import tempfile
import time
import zlib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True, type=Path)
parser.add_argument("--style", required=True, type=Path)
parser.add_argument("--loader-cache", type=Path)
args = parser.parse_args()
for tool in ("labwc", "grim", "wlr-randr", "wtype", "dbus-send"):
    if shutil.which(tool) is None:
        parser.error(f"Missing executable: {tool}")
root = Path(tempfile.mkdtemp(prefix="desktop-osd-check-"))
print(f"Artifacts: {root}", flush=True)
(root / "runtime").mkdir(mode=0o700)
(root / "config/labwc").mkdir(parents=True)
(root / "config/labwc/rc.xml").write_text("<labwc_config />")
(root / "config/labwc/autostart").write_text("")
(root / "config/labwc/environment").write_text("LABWC_UPDATE_ACTIVATION_ENV=false\n")
(root / "mock").mkdir()
state_file = root / "state.json"
state_file.write_text(
    json.dumps({"volume": 50, "muted": True, "mic_muted": False, "brightness": 20})
)
mock = root / "mock/backend"
mock.write_text(
    f"#!{sys.executable}\n"
    + r"""
import fcntl, json, os, sys, time
from pathlib import Path
root = Path(os.environ['OSD_TEST_ROOT'])
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root/'calls.log').open('a') as f:
    f.write(json.dumps([tool, args])+'\n')
if tool == 'pw-play':
    with (root/'sound.lock').open('w') as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            (root/'sound-overlap').touch()
            sys.exit(1)
        with (root/'sounds.log').open('a') as f: f.write('sound\n')
        time.sleep(.8)
    sys.exit(0)
path = root/'state.json'
state = json.loads(path.read_text())
def save():
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(state))
    temp.replace(path)
if state.pop('fail', False):
    save()
    print('fixture backend failure', file=sys.stderr)
    sys.exit(1)
if state.pop('hang', False):
    save()
    time.sleep(10)
if tool == 'wpctl':
    is_mic = '@DEFAULT_AUDIO_SOURCE@' in args
    muted = 'mic_muted' if is_mic else 'muted'
    if args[0] == 'get-volume':
        print('Volume: %.2f%s' % ((65 if is_mic else state['volume'])/100,
                                 ' [MUTED]' if state[muted] else ''))
    elif args[0] == 'set-mute':
        state[muted] = not state[muted] if args[-1] == 'toggle' else args[-1] == '1'
        save()
    elif args[0] == 'set-volume':
        assert args[1:3] == ['-l', '1.0']
        state['volume'] = float(args[-1].removesuffix('%'))
        assert 0 <= state['volume'] <= 100
        save()
    else: raise ValueError(args)
elif tool == 'brightnessctl':
    assert args[:2] == ['-c', 'backlight']
    if args[2] == 'set':
        state['brightness'] = float(args[3].removesuffix('%'))
        assert 5 <= state['brightness'] <= 100
        save()
    else: assert args[2] == '-m'
    print('intel,backlight,%d,%d%%,400' % (state['brightness']*4, state['brightness']))
else: raise ValueError(tool)
"""
)
mock.chmod(0o755)
for tool in ("wpctl", "brightnessctl", "pw-play"):
    (root / "mock" / tool).symlink_to(mock)
env = dict(os.environ)
for name in ("DISPLAY", "WAYLAND_DISPLAY", "LABWC_PID", "GDK_PIXBUF_MODULE_FILE"):
    env.pop(name, None)
env.update(
    PATH=str(root / "mock") + ":" + env["PATH"],
    OSD_TEST_ROOT=str(root),
    XDG_RUNTIME_DIR=str(root / "runtime"),
    XDG_CONFIG_HOME=str(root / "config"),
    XDG_DATA_DIRS="/run/current-system/sw/share",
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
    return json.loads(state_file.read_text())


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


try:
    compositor = start(["labwc", "-C", str(root / "config/labwc")], "labwc.log")
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
    start(["wtype", "-s", "55000"], "keyboard.log")
    start(
        [
            str(args.binary.parent / "labwc-switcher-fixture"),
            "org.dotfiles.OsdFocusFixture",
            "OSD focus fixture",
        ],
        "focus.log",
    )
    wait_for(lambda: "OSD focus fixture" in (root / "focus.log").read_text())
    time.sleep(0.2)
    server = start(
        [str(args.binary), "serve", str(args.style)],
        "osd.log",
        {"G_DEBUG": "fatal-criticals", "WAYLAND_DEBUG": "1"},
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
    time.sleep(0.1)
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
    assert not re.search(r"wl_keyboard#\d+\.enter\(", log()), "OSD stole keyboard focus"
    print(
        "PASS unmute, volume step, two passive overlays and icon rendering", flush=True
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
    assert not (root / "sound-overlap").exists()
    assert len((root / "sounds.log").read_text().splitlines()) < 26
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
        "PASS key repeat, 100 percent cap, mute toggles and non-overlapping feedback",
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
    # A failed or hung backend must not block subsequent media keys.
    for mode in ("fail", "hang"):
        data = state()
        data[mode] = True
        state_file.write_text(json.dumps(data))
        send("volume", "down")
        wait_for(lambda mode=mode: mode not in state())
        send("brightness", "down")
        expected = 95 if mode == "fail" else 90
        wait_for(lambda expected=expected: state()["brightness"] == expected)
    print("PASS backend failure, timeout and queue recovery", flush=True)
    run(
        [
            "wlr-randr",
            "--output",
            "HEADLESS-1",
            "--custom-mode",
            "2808x1755",
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
    assert server.poll() is None
    assert not re.search(r"CRITICAL|panic:|assertion", log()), log()[-3000:]
    assert len((root / "focus.log").read_text().splitlines()) == 1, (
        "Application focus changed"
    )
    print("PASS fractional scale and output disable/reenable", flush=True)
    server.terminate()
    assert server.wait(timeout=5) == 0
    print("PASS clean shutdown", flush=True)
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except sp.TimeoutExpired:
                process.kill()
                process.wait()
