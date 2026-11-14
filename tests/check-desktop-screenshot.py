"""Test native capture and selection in an isolated headless Wayland session.

Run under dbus-run-session; requires wtype, wlr-randr and wl-paste on PATH.
"""

import argparse
import os
from pathlib import Path
import subprocess as sp
import tempfile
import time
from session_fixture import VirtualPointer, png_size as dimensions, terminate_processes, wait_wayland

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bin-dir", required=True, type=Path)
parser.add_argument("--pointer-fixture", type=Path)
args = parser.parse_args()
command = [str(args.bin_dir / "desktop-zig"), "screenshot"]
root = Path(tempfile.mkdtemp(prefix="desktop-screenshot-check-"))
print(f"Artifacts: {root}", flush=True)
(root / "runtime").mkdir(mode=0o700)
(root / "config").mkdir(parents=True)
(root / "config/user-dirs.dirs").write_text(f'XDG_PICTURES_DIR="{root}/photos"\n')
env = dict(os.environ)
for key in ("DISPLAY", "WAYLAND_DISPLAY"):
    env.pop(key, None)
env.update(
    HOME=str(root),
    XDG_RUNTIME_DIR=str(root / "runtime"),
    XDG_CONFIG_HOME=str(root / "config"),
    XDG_CACHE_HOME=str(root / "cache"),
    WLR_BACKENDS="headless",
    WLR_RENDERER="pixman",
    WLR_HEADLESS_OUTPUTS="2",
    NO_AT_BRIDGE="1",
    GTK_USE_PORTAL="0",
    GIO_USE_VFS="local",
    GDK_BACKEND="invalid-native-test",
)
processes = []


def start(command, name, **kwargs):
    with (root / name).open("w") as log:
        process = sp.Popen(command, env=env, stderr=log, **kwargs)
    processes.append(process)
    return process


def run(command):
    return sp.run(command, env=env, capture_output=True, check=True, timeout=10)


def saved():
    return list((root / "photos/Screenshots").glob("*.png"))


try:
    compositor = start(["desktop-zig", "compositor-only"], "compositor.log", stdout=sp.DEVNULL)
    env["WAYLAND_DISPLAY"] = wait_wayland(root / "runtime", compositor, root / "compositor.log")
    run(["wlr-randr", "--output", "HEADLESS-1", "--pos", "0,0"])
    run(["wlr-randr", "--output", "HEADLESS-2", "--pos", "1280,0"])
    explicit = root / "explicit.png"
    run([*command, "-g", "10,20 64x48", str(explicit)])
    assert dimensions(explicit) == (64, 48)
    stdout = run([*command, "-g", "10,20 64x48", "-"]).stdout
    assert stdout == explicit.read_bytes(), "stdout PNG differs from saved capture"
    run([*command, "-g", "10,20 64x48"])
    assert len(saved()) == 1 and dimensions(saved()[0]) == (64, 48)
    run([*command, "-g", "10,20 64x48"])
    assert len(saved()) == 2, "Successive captures overwrote a file"

    pointer = VirtualPointer(
        args.pointer_fixture or args.bin_dir / "desktop-pointer-fixture",
        env=env,
        stderr=(root / "pointer.log").open("w"),
        delay=0.06,
    )
    processes.append(pointer.process)
    point = pointer.command

    point("size 2560 720")
    start(["wtype", "-s", "55000"], "keyboard.log", stdout=sp.DEVNULL)

    def choose(arguments, name, steps):
        slurp = "--slurp" in arguments
        capture = start([*command, *arguments], name + ".log", stdout=sp.PIPE if slurp else sp.DEVNULL, text=True)
        time.sleep(0.5)
        for instruction in steps:
            point(instruction)
        if slurp:
            stdout, _ = capture.communicate(timeout=10)
        else:
            capture.wait(timeout=10)
            stdout = ""
        return capture.returncode, stdout

    code, _ = choose([], "interactive", ("move 100 90", "button 1", "move 400 270", "button 0"))
    assert code == 0, (root / "interactive.log").read_text()
    assert len(saved()) == 3
    newest = max(saved(), key=lambda path: path.stat().st_mtime_ns)
    assert dimensions(newest) == (300, 180)
    clipboard = run(["wl-paste", "--type", "image/png"]).stdout
    assert clipboard.startswith(b"\x89PNG\r\n\x1a\n"), "Clipboard image missing"
    print("PASS: region capture, default saving, native selection, and clipboard", flush=True)

    code, text = choose(["--slurp"], "reverse", ("move 400 270", "button 1", "move 100 90", "button 0"))
    assert code == 0 and text.strip() == "100,90 300x180", (code, text)
    code, text = choose(["--slurp"], "tiny", ("move 100 90", "button 1", "move 103 93", "button 0"))
    assert code == 1 and not text

    previous = len(saved())
    cancelled = start(command, "cancelled.log", stdout=sp.DEVNULL)
    time.sleep(0.5)
    point("move 100 90")
    point("button 1")
    point("move 400 270")
    run(["wtype", "-k", "Escape"])
    point("button 0")
    assert cancelled.wait(timeout=10) == 0
    assert len(saved()) == previous, "Escape saved a screenshot"
    print("PASS: reverse drags, tiny selection rejection, and Escape cancellation", flush=True)

    second = root / "second.png"
    code, _ = choose(["-i", "-o", "HEADLESS-2", str(second)], "second", ("move 1380 90", "button 1", "move 1680 270", "button 0"))
    assert code == 0 and dimensions(second) == (300, 180)
    code, text = choose(["--slurp", "-o", "HEADLESS-2"], "global", ("move 1380 90", "button 1", "move 1680 270", "button 0"))
    assert code == 0 and text.strip() == "1380,90 300x180", (code, text)
    print("PASS: requested output and global slurp coordinates", flush=True)

    run(["wlr-randr", "--output", "HEADLESS-2", "--scale", "2"])
    time.sleep(0.2)
    point("size 1920 720")
    scaled = root / "scaled.png"
    code, _ = choose(["-i", "-o", "HEADLESS-2", str(scaled)], "scaled", ("move 1440 90", "button 1", "move 1680 270", "button 0"))
    assert code == 0 and dimensions(scaled) == (480, 360)
    print("PASS: scaled selection uses logical input coordinates and physical capture pixels", flush=True)

finally:
    terminate_processes(processes)
