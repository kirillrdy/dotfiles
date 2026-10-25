#!/usr/bin/env python3
"""Check Firefox capture bounds and live overview stability in private Labwc.

Requires Pillow, dbus-run-session, grim and wlr-randr on PATH.
"""

import argparse
import os
from pathlib import Path
import re
import subprocess as sp
import sys
import tempfile
import time

from PIL import Image, ImageChops


def main():
    if not os.environ.get("FIREFOX_OVERVIEW_TEST_BUS"):
        os.execvpe("dbus-run-session", ["dbus-run-session", sys.executable,
                    __file__, *sys.argv[1:]],
                   dict(os.environ, FIREFOX_OVERVIEW_TEST_BUS="1"))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--labwc", required=True)
    parser.add_argument("--firefox", required=True)
    parser.add_argument("--wallpaper", required=True)
    parser.add_argument("--video", type=Path, help="Loop a local video instead of CSS animation")
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    args.artifacts.mkdir(parents=True, exist_ok=True)
    processes = []
    with tempfile.TemporaryDirectory(prefix="firefox-overview-") as directory:
        root = Path(directory)
        (root / "runtime").mkdir(mode=0o700)
        config = root / "config/labwc"
        config.mkdir(parents=True)
        (config / "rc.xml").write_text(
            "<labwc_config><desktops><number>4</number></desktops></labwc_config>"
        )
        (config / "autostart").write_text("")
        (config / "environment").write_text("LABWC_UPDATE_ACTIVATION_ENV=false\n")
        profile = root / "profile"
        profile.mkdir()
        (profile / "user.js").write_text(
            'user_pref("browser.shell.checkDefaultBrowser", false);\n'
            'user_pref("browser.aboutwelcome.enabled", false);\n'
            'user_pref("browser.startup.homepage_override.mstone", "ignore");\n'
        )
        page = root / "animated.html"
        page.write_text(
            "<style>body {background:#ffcc00} div {width:200px;height:200px;"
            "background:#0044ff;animation:move .5s infinite alternate}"
            "@keyframes move {to {transform:translateX(200px)}}</style><div></div>"
        )
        if args.video:
            from html import escape

            page.write_text(
                '<style>body {margin:0;background:#ffcc00} video {width:100%;height:100vh}</style>'
                f'<video autoplay muted loop src="{escape(args.video.resolve().as_uri(), quote=True)}"></video>'
            )
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root / "runtime"),
                   XDG_CONFIG_HOME=str(root / "config"),
                   XDG_CACHE_HOME=str(root / "cache"),
                   WLR_BACKENDS="headless", WLR_RENDERER="gles2",
                   WLR_HEADLESS_OUTPUTS="1", LABWC_UPDATE_ACTIVATION_ENV="false",
                   MOZ_ENABLE_WAYLAND="1", GDK_BACKEND="wayland", GTK_USE_PORTAL="0")
        for key in ["DISPLAY", "WAYLAND_DISPLAY", "LABWC_PID"]:
            env.pop(key, None)

        def start(command, name, **extra):
            process = sp.Popen(command, env=dict(env, **extra),
                               stdout=(args.artifacts / f"{name}.log").open("w"),
                               stderr=sp.STDOUT)
            processes.append(process)

        def run(command):
            sp.run(command, env=env, check=True, capture_output=True, timeout=15)

        def wait_for(condition, message):
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if condition():
                    return
                time.sleep(0.05)
            raise AssertionError(message)

        log = args.artifacts / "overview.log"
        try:
            start([args.labwc, "-C", str(config)], "labwc")
            wait_for(lambda: (root / "runtime/wayland-0").exists(), "Labwc did not start")
            env["WAYLAND_DISPLAY"] = "wayland-0"
            run(["wlr-randr", "--output", "HEADLESS-1", "--custom-mode", "1728x1080",
                 "--scale", "2"])
            start([args.firefox, "--no-remote", "--profile", str(profile), page.as_uri()],
                  "firefox", WAYLAND_DEBUG="client")
            firefox_log = args.artifacts / "firefox.log"
            wait_for(lambda: ".set_window_geometry(" in firefox_log.read_text(),
                     "Firefox did not map a window")
            time.sleep(1)
            start([str(args.bin_dir / "desktop-overview"), args.wallpaper],
                  "overview", WAYLAND_DEBUG="client")
            wait_for(lambda: log.exists() and log.read_text().count(".ready()") >= 4,
                     "Firefox preview did not update live")
            time.sleep(1)
            text = log.read_text()
            geometry = re.search(r'\.window\("[^"]+", \d+, -?\d+, -?\d+, (\d+), (\d+),', text)
            assert geometry, "Missing Firefox window geometry"
            sizes = re.findall(r"\.buffer_size\((\d+), (\d+)\)", text)
            assert sizes and all(size == geometry.groups() for size in sizes), (
                f"Firefox capture includes invisible surfaces: {sizes}, window {geometry.groups()}"
            )
            baseline = None
            animated = False
            for index in range(15):
                path = args.artifacts / f"frame-{index}.png"
                run(["grim", str(path)])
                current = Image.open(path).convert("RGB")
                if baseline is None:
                    baseline = current
                else:
                    difference = ImageChops.difference(baseline, current)
                    # Allow motion in the central preview and workspace strip.
                    animated |= difference.getbbox() is not None
                    for box in [(0, 0, 1728, 140), (0, 240, 430, 1080),
                                (1300, 240, 1728, 1080), (0, 800, 1728, 1080)]:
                        assert difference.crop(box).getbbox() is None, (
                            f"Overview flashed outside the preview in frame {index}"
                        )
                time.sleep(0.15)
            assert animated, "Firefox animation froze in the preview"
            assert all(p.poll() is None for p in processes), "A test application exited"
            content = "video playback" if args.video else "live animation"
            print(f"PASS: Firefox capture bounds, {content} and stable overview at scale 2")
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except sp.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    main()
