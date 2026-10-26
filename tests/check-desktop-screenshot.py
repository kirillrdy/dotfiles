"""Test capture, default saving and selection in an isolated Labwc session.

Run under dbus-run-session; requires labwc and wl-paste on PATH.
"""

import argparse
import os
from pathlib import Path
import select
import struct
import subprocess as sp
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bin-dir", required=True, type=Path)
args = parser.parse_args()
binary = args.bin_dir / "desktop-screenshot"
root = Path(tempfile.mkdtemp(prefix="desktop-screenshot-check-"))
print(f"Artifacts: {root}", flush=True)
(root / "runtime").mkdir(mode=0o700)
config = root / "config/labwc"
config.mkdir(parents=True)
(config / "rc.xml").write_text("<labwc_config />")
(config / "autostart").write_text("")
(config / "environment").write_text("LABWC_UPDATE_ACTIVATION_ENV=false\n")
(root / "config/user-dirs.dirs").write_text(f'XDG_PICTURES_DIR="{root}/photos"\n')
env = dict(os.environ)
for key in ("DISPLAY", "WAYLAND_DISPLAY", "LABWC_PID"):
    env.pop(key, None)
env.update(
    HOME=str(root),
    XDG_RUNTIME_DIR=str(root / "runtime"),
    XDG_CONFIG_HOME=str(root / "config"),
    XDG_CACHE_HOME=str(root / "cache"),
    WLR_BACKENDS="headless",
    WLR_RENDERER="pixman",
    WLR_HEADLESS_OUTPUTS="1",
    LABWC_UPDATE_ACTIVATION_ENV="false",
    NO_AT_BRIDGE="1",
    GTK_USE_PORTAL="0",
    GIO_USE_VFS="local",
)
processes = []


def start(command, name, **kwargs):
    with (root / name).open("w") as log:
        process = sp.Popen(command, env=env, stderr=log, **kwargs)
    processes.append(process)
    return process


def run(command):
    return sp.run(command, env=env, capture_output=True, check=True, timeout=10)


def dimensions(path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    return struct.unpack(">II", data[16:24])


def saved():
    return list((root / "photos/Screenshots").glob("*.png"))


try:
    compositor = start(["labwc"], "labwc.log", stdout=sp.DEVNULL)
    deadline = time.monotonic() + 10
    while not list((root / "runtime").glob("wayland-*.lock")):
        assert compositor.poll() is None, (root / "labwc.log").read_text()
        assert time.monotonic() < deadline, "Compositor startup timed out"
        time.sleep(0.05)
    env["WAYLAND_DISPLAY"] = next((root / "runtime").glob("wayland-*.lock")).stem
    explicit = root / "explicit.png"
    run([str(binary), "-g", "10,20 64x48", str(explicit)])
    assert dimensions(explicit) == (64, 48)
    run([str(binary), "-g", "10,20 64x48"])
    assert len(saved()) == 1 and dimensions(saved()[0]) == (64, 48)
    run([str(binary), "-g", "10,20 64x48"])
    assert len(saved()) == 2, "Successive captures overwrote a file"

    pointer = start(
        [str(args.bin_dir / "desktop-pointer-fixture")],
        "pointer.log", stdin=sp.PIPE, stdout=sp.PIPE, text=True,
    )
    assert select.select([pointer.stdout], [], [], 5)[0]
    assert pointer.stdout.readline().strip() == "ready"
    capture = start([str(binary)], "interactive.log", stdout=sp.DEVNULL)
    time.sleep(0.7)
    for command in ("move 100 100", "button 1", "move 400 300", "button 0"):
        pointer.stdin.write(command + "\n")
        pointer.stdin.flush()
        assert select.select([pointer.stdout], [], [], 5)[0]
        assert pointer.stdout.readline().strip() == "ok"
        time.sleep(0.1)
    assert capture.wait(timeout=10) == 0, (root / "interactive.log").read_text()
    assert len(saved()) == 3, (root / "interactive.log").read_text()
    clipboard = run(["wl-paste", "--type", "image/png"]).stdout
    assert clipboard.startswith(b"\x89PNG\r\n\x1a\n"), "Clipboard image missing"
    print("PASS: region capture, default Pictures saving, unique names, selection and clipboard")
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except sp.TimeoutExpired:
                process.kill()
                process.wait()
