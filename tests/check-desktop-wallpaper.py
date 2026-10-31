"""Check native wallpaper rendering and output lifecycle without GTK/GDK init."""
import argparse
import os
from pathlib import Path
import re
import subprocess as sp
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bin-dir", type=Path, required=True)
parser.add_argument("--grim", required=True)
parser.add_argument("--wlr-randr", required=True)
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="desktop-wallpaper-check-", dir="/tmp"))
print(f"Artifacts: {root}", flush=True)
(root / "runtime").mkdir(mode=0o700)
env = dict(os.environ, XDG_RUNTIME_DIR=str(root / "runtime"),
           WLR_BACKENDS="headless", WLR_RENDERER="pixman", WLR_HEADLESS_OUTPUTS="2",
           WAYLAND_DISPLAY="wayland-0", WAYLAND_DEBUG="client",
           # Fail immediately if the wallpaper accidentally initializes GDK.
           GDK_BACKEND="invalid-wallpaper-test-backend", G_DEBUG="fatal-criticals")
env.pop("DISPLAY", None)
bin = args.bin_dir.resolve()
processes = []


def start(command, name):
    with (root / f"{name}.log").open("w") as log:
        process = sp.Popen(command, env=env, stdout=log, stderr=sp.STDOUT)
    processes.append(process)
    return process


def run(command):
    result = sp.run(command, env=env, capture_output=True, timeout=10)
    assert result.returncode == 0, (command, result.stderr.decode())
    return result


def wait(check, description):
    deadline = time.monotonic() + 10
    while not check():
        assert server.poll() is None, (root / "server.log").read_text()
        if time.monotonic() >= deadline:
            details = "\n".join(path.read_text()[-6000:] for path in root.glob("*.log"))
            raise AssertionError(description + "\n" + details)
        time.sleep(0.05)


def image(name, vertical):
    width, height = (4, 120) if vertical else (120, 4)
    colors = (bytes([255, 0, 0]), bytes([0, 255, 0]), bytes([0, 0, 255]))
    pixels = b"".join(colors[(y if vertical else x) // 40]
                      for y in range(height) for x in range(width))
    path = root / name
    path.write_bytes(f"P6\n{width} {height}\n255\n".encode() + pixels)
    return path


def green(output, label):
    path = root / f"{label}-{output}.ppm"
    run([args.grim, "-o", output, "-t", "ppm", str(path)])
    magic, dimensions, maximum, pixels = path.read_bytes().split(b"\n", 3)
    assert magic == b"P6" and maximum == b"255"
    width, height = map(int, dimensions.split())
    assert len(pixels) == width * height * 3
    # Opposite edges and the center must all be filled by the middle band.
    return all(pixels[(y * width + x) * 3:][:3] == b"\x00\xff\x00"
               for y in (1, height // 2, height - 2)
               for x in (1, width // 2, width - 2))


def screenshot(output, label):
    wait(lambda: wallpaper.poll() is None and green(output, label), label)


def configure(*options):
    run([args.wlr_randr, "--output", "HEADLESS-1", *options])


try:
    server = start([str(bin / "desktop-zig"), "compositor-only"], "server")
    wait(lambda: (root / "runtime/wayland-0").exists(), "compositor socket")
    for name, vertical in (("wide", False), ("tall", True)):
        wallpaper = start([str(bin / "desktop-wallpaper-fixture"), str(image(name + ".ppm", vertical))], name)
        screenshot("HEADLESS-1", name)
        screenshot("HEADLESS-2", name)
        time.sleep(0.15)
        commits = (root / f"{name}.log").read_text().count(".attach(")
        time.sleep(0.15)
        assert (root / f"{name}.log").read_text().count(".attach(") == commits, "idle repaint loop"
        for scale in ("2", "1.25", "1"):
            configure("--scale", scale)
            screenshot("HEADLESS-1", name + "-scale-" + scale)
            screenshot("HEADLESS-2", name + "-unchanged-" + scale)
        configure("--custom-mode", "800x600@60Hz")
        screenshot("HEADLESS-1", name + "-resized")
        # Removing an output from the layout withdraws its wl_output global;
        # re-enabling it advertises a new global to the existing client.
        configure("--off")
        screenshot("HEADLESS-2", name + "-removed")
        configure("--on")
        screenshot("HEADLESS-1", name + "-reconnected")
        wallpaper.terminate()
        assert wallpaper.wait(timeout=5) == 0
        log = (root / f"{name}.log").read_text()
        assert len(re.findall(r'get_layer_surface\(.*"desktop-wallpaper"', log)) >= 3, log[-4000:]
        assert "set_input_region(wl_region" in log
        assert "set_keyboard_interactivity(0)" in log
        assert re.search(r"wl_output[#@]\d+\.release\(\)", log), "output resource not released"
        assert "set_buffer_scale(2)" in log
        assert re.search(r"create_buffer\(.*800, 600, 3200, 1\)", log), "missing resized buffer"
        assert not re.search(r"CRITICAL|panic:|error:|Segmentation", log), log[-4000:]
    assert server.poll() is None
    print("PASS native wallpaper: centered crop, two outputs, integer/fractional scales, resize, "
          "output removal/re-addition, input transparency, and clean shutdown", flush=True)
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except sp.TimeoutExpired:
                process.kill()
                process.wait()
