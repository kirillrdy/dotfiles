"""Test capture, default saving and selection in an isolated desktop session.

Run under dbus-run-session; requires desktop-zig and wl-paste on PATH.
"""

import argparse
import os
from pathlib import Path
import select
import struct
import subprocess as sp
import tempfile
import time
import zlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bin-dir", required=True, type=Path)
args = parser.parse_args()
command = [str(args.bin_dir / "desktop-zig"), "screenshot"]
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


def png_dimensions(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", data[16:29])
    assert depth == 8 and color in (2, 6)
    assert (compression, filtering, interlace) == (0, 0, 0)
    offset = 8
    compressed = bytearray()
    while offset < len(data):
        size = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + size]
        checksum = struct.unpack(">I", data[offset + 8 + size:offset + 12 + size])[0]
        assert zlib.crc32(kind + payload) == checksum, "PNG chunk checksum"
        if kind == b"IDAT":
            compressed.extend(payload)
        offset += size + 12
    assert offset == len(data) and kind == b"IEND"
    pixels = zlib.decompress(compressed)
    stride = width * (4 if color == 6 else 3) + 1
    assert len(pixels) == stride * height
    assert all(pixels[y * stride] in range(5) for y in range(height))
    return width, height


def dimensions(path):
    return png_dimensions(path.read_bytes())


def saved():
    return list((root / "photos/Screenshots").glob("*.png"))


try:
    compositor = start(["desktop-zig", "compositor-only"], "labwc.log", stdout=sp.DEVNULL)
    deadline = time.monotonic() + 10
    while not list((root / "runtime").glob("wayland-*.lock")):
        assert compositor.poll() is None, (root / "labwc.log").read_text()
        assert time.monotonic() < deadline, "Compositor startup timed out"
        time.sleep(0.05)
    env["WAYLAND_DISPLAY"] = next((root / "runtime").glob("wayland-*.lock")).stem
    explicit = root / "explicit.png"
    run([*command, "-g", "10,20 64x48", str(explicit)])
    assert dimensions(explicit) == (64, 48)
    stdout = run([*command, "-g", "10,20 64x48", "-"]).stdout
    assert png_dimensions(stdout) == (64, 48)
    run([*command, "-g", "10,20 64x48"])
    assert len(saved()) == 1 and dimensions(saved()[0]) == (64, 48)
    run([*command, "-g", "10,20 64x48"])
    assert len(saved()) == 2, "Successive captures overwrote a file"

    pointer = start(
        [str(args.bin_dir / "desktop-pointer-fixture")],
        "pointer.log", stdin=sp.PIPE, stdout=sp.PIPE, text=True,
    )
    assert select.select([pointer.stdout], [], [], 5)[0]
    assert pointer.stdout.readline().strip() == "ready"
    capture = start(command, "interactive.log", stdout=sp.DEVNULL)
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
    png_dimensions(clipboard)
    assert clipboard in [path.read_bytes() for path in saved()], "Clipboard differs from saved capture"
    print("PASS: region capture, stdout, default Pictures saving, unique names, selection, clipboard and PNG checksums")
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except sp.TimeoutExpired:
                process.kill()
                process.wait()
