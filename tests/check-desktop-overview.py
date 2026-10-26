#!/usr/bin/env python3
"""Exercise the overview in a private D-Bus/headless Labwc session.

Requires grim, wlr-randr and wtype on PATH. Pass --bin-dir, --labwc
and --wallpaper for the build being checked; the current desktop is untouched.
"""

import argparse
import os
import re
import select
import subprocess as sp
import sys
import tempfile
import time
from pathlib import Path


def main():
    if not os.environ.get("DESKTOP_OVERVIEW_TEST_BUS"):
        env = dict(os.environ, DESKTOP_OVERVIEW_TEST_BUS="1")
        os.execvpe(
            "dbus-run-session",
            ["dbus-run-session", sys.executable, __file__, *sys.argv[1:]],
            env,
        )
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--labwc", required=True)
    parser.add_argument("--wallpaper", required=True)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--renderer", choices=["pixman", "gles2"], default="pixman")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="desktop-overview-") as directory:
        root = Path(directory)
        artifacts = args.artifacts or root / "artifacts"
        artifacts.mkdir(parents=True, exist_ok=True)
        runtime = root / "runtime"
        runtime.mkdir(mode=0o700)
        config = root / "config/labwc"
        config.mkdir(parents=True)
        (config / "rc.xml").write_text(
            "<labwc_config><desktops><names><name>1</name><name>2</name>"
            "<name>3</name><name>4</name></names></desktops></labwc_config>"
        )
        (config / "environment").write_text("LABWC_UPDATE_ACTIVATION_ENV=false\n")
        (config / "autostart").write_text("")
        gtk_config = root / "config/gtk-3.0"
        gtk_config.mkdir()
        (gtk_config / "settings.ini").write_text(
            "[Settings]\ngtk-enable-animations=0\n"
        )
        settings = root / "config/glib-2.0/settings"
        settings.mkdir(parents=True)
        (settings / "keyfile").write_text("[org/gnome/shell]\nfavorite-apps=[]\n")
        data = root / "data/applications"
        data.mkdir(parents=True)
        for app, icon in [
            ("Browser", "web-browser"),
            ("Terminal", "utilities-terminal"),
            ("Files", "system-file-manager"),
        ]:
            (data / f"io.test.{app}.desktop").write_text(
                f"[Desktop Entry]\nType=Application\nName={app}\nExec=true\nIcon={icon}\n"
            )
        env = dict(os.environ)
        for key in ["DISPLAY", "WAYLAND_DISPLAY", "LABWC_PID"]:
            env.pop(key, None)
        env.update(
            XDG_RUNTIME_DIR=str(runtime),
            XDG_CONFIG_HOME=str(root / "config"),
            XDG_DATA_HOME=str(root / "data"),
            WLR_BACKENDS="headless",
            WLR_RENDERER=args.renderer,
            WLR_HEADLESS_OUTPUTS="1",
            LABWC_UPDATE_ACTIVATION_ENV="false",
            NO_AT_BRIDGE="1",
            GTK_USE_PORTAL="0",
            GIO_USE_VFS="local",
            GSETTINGS_BACKEND="keyfile",
            G_DEBUG="fatal-criticals",
        )
        processes = []
        pointer = None

        def start(command, name, **extra):
            process = sp.Popen(
                command,
                env=dict(env, **extra),
                stdout=(artifacts / f"{name}.log").open("w"),
                stderr=sp.STDOUT,
            )
            processes.append(process)
            return process

        def run(command):
            return sp.run(
                command, env=env, capture_output=True, text=True, check=True, timeout=15
            ).stdout

        def wait_for(condition, message):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if condition():
                    return
                time.sleep(0.05)
            raise AssertionError(message)

        def pointer_command(command):
            pointer.stdin.write(command + "\n")
            pointer.stdin.flush()
            assert select.select([pointer.stdout], [], [], 5)[0], (
                "Virtual pointer timed out"
            )
            assert pointer.stdout.readline().strip() == "ok"

        def click(x, y):
            pointer_command(f"move {x} {y}")
            pointer_command("button 1")
            pointer_command("button 0")
            time.sleep(0.3)

        def key(name):
            run(["wtype", "-k", name])
            time.sleep(0.3)

        def shot(name):
            path = artifacts / f"{name}.png"
            run(["grim", "-s", "1", "-g", "300,180 1120x740", str(path)])
            return path.read_bytes()

        overview_command = [str(args.bin_dir / "desktop-overview"), args.wallpaper]
        log_path = artifacts / "overview.log"

        def log():
            return log_path.read_text()

        def reopen():
            run(overview_command)
            time.sleep(0.6)

        try:
            compositor = start([args.labwc, "-C", str(config)], "labwc")
            wait_for(
                lambda: (runtime / "wayland-0").exists(), "Compositor did not start"
            )
            env["WAYLAND_DISPLAY"] = "wayland-0"
            run(["wlr-randr", "--output", "HEADLESS-1", "--custom-mode", "1728x1080"])
            pointer = sp.Popen(
                [str(args.bin_dir / "desktop-pointer-fixture")],
                env=env,
                stdin=sp.PIPE,
                stdout=sp.PIPE,
                stderr=(artifacts / "pointer.log").open("w"),
                text=True,
            )
            processes.append(pointer)
            assert select.select([pointer.stdout], [], [], 5)[0], (
                "Virtual pointer did not start"
            )
            assert pointer.stdout.readline().strip() == "ready"
            panel_config = root / "panel.json"
            panel_config.write_text(
                '{"left":[],"center":[{"kind":"clock","name":"gnome-clock"}],"right":[]}'
            )
            panel_style = root / "panel.css"
            panel_style.write_text("window#desktop-panel { background: black; }")
            start(
                [
                    str(args.bin_dir / "desktop-panel"),
                    str(panel_config),
                    str(panel_style),
                ],
                "panel",
            )
            # Headless wlroots starts without a keyboard; keep one connected.
            start(["wtype", "-k", "Shift_L", "-s", "60000"], "keyboard")
            time.sleep(0.2)
            fixtures = []
            for index, (app, title) in enumerate(
                [
                    ("Browser", "Same title"),
                    ("Browser", "Same title"),
                    ("Terminal", "Terminal"),
                    ("Files", "Files"),
                ]
            ):
                extra = {"DESKTOP_FIXTURE_ANIMATE": "1"} if index == 0 else {}
                fixtures.append(
                    start(
                        [
                            str(args.bin_dir / "labwc-switcher-fixture"),
                            f"io.test.{app}",
                            title,
                        ],
                        f"window-{index}",
                        **extra,
                    )
                )
                time.sleep(0.2)
            overview = start(overview_command, "overview", WAYLAND_DEBUG="client")
            wait_for(
                lambda: log().count(".ready()") >= 8,
                "Window captures did not update live",
            )
            first = shot("live-before")
            time.sleep(0.5)
            assert first != shot("live-after"), (
                "Occluded live window did not update in the overview"
            )
            assert len(re.findall(r'\.workspace\(\d+, "[1-4]",', log())) >= 4
            initial_ids = list(
                dict.fromkeys(
                    re.findall(r'dotfiles_overview_v1#\d+\.window\("([^"]+)"', log())
                )
            )
            run(
                ["grim", "-s", "1", "-o", "HEADLESS-1", str(artifacts / "overview.png")]
            )
            before = (artifacts / "window-0.log").read_text().splitlines()
            other_before = (artifacts / "window-1.log").read_text().splitlines()
            click(584, 350)
            wait_for(
                lambda: (
                    len((artifacts / "window-0.log").read_text().splitlines())
                    > len(before)
                ),
                "Clicked duplicate-title window did not gain focus",
            )
            assert (
                artifacts / "window-1.log"
            ).read_text().splitlines() == other_before, (
                "Wrong duplicate-title window gained focus"
            )
            time.sleep(0.2)
            ready_count = log().count(".ready()")
            time.sleep(0.5)
            assert log().count(".ready()") == ready_count, (
                "Capture continued after hiding the overview"
            )
            reopen()
            click(828, 126)
            wait_for(
                lambda: '.workspace(1, "2", 1)' in log(),
                "Workspace thumbnail did not switch",
            )
            key("Return")
            assert overview.poll() is None
            click(756, 126)
            key("Page_Down")
            assert log().count('.workspace(1, "2", 1)') >= 2, (
                "Keyboard workspace navigation failed"
            )
            key("Page_Up")
            pointer_command("move 1120 760")
            pointer_command("button 1")
            for x, y in [(1050, 600), (950, 400), (850, 200), (828, 126)]:
                pointer_command(f"move {x} {y}")
                time.sleep(0.05)
            pointer_command("button 0")
            wait_for(
                lambda: f'.window("{initial_ids[3]}", 1,' in log(),
                "Dragging a window to another workspace failed",
            )
            run(["wtype", "Files"])
            time.sleep(0.5)
            shot("search")
            key("Escape")
            click(984, 1018)
            shot("applications")
            key("Escape")
            click(848, 176)
            wait_for(
                lambda: fixtures[0].poll() == 0,
                "Window close button did not close the selected window",
            )
            assert fixtures[1].poll() is None, (
                "Closing a duplicate-title window closed its sibling"
            )
            assert overview.poll() is None, log()[-4000:]
            key("Escape")
            reopen()
            key("Super_L")
            maps = len(re.findall(r'get_layer_surface\(.*"desktop-overview"', log()))
            unmaps = len(re.findall(r"-> zwlr_layer_surface_v1#\d+\.destroy\(", log()))
            assert maps == unmaps, "Super did not hide the overview"
            assert compositor.poll() is None
            assert not re.search(r"CRITICAL|panic:|protocol error", log()), log()[
                -4000:
            ]
            print(
                "PASS: live occluded captures, exact activation, idle cleanup, workspaces, drag, keyboard, search, app grid and close"
            )
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except sp.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    main()
