#!/usr/bin/env python3
"""Exercise the overview in a private D-Bus/headless Wayland session.

Requires grim, wlr-randr and wtype on PATH. Pass --bin-dir, --compositor
and --wallpaper for the build being checked; the current desktop is untouched.
"""

import argparse
from ime_fixture import InputMethod
from session_fixture import Processes, command as session_command, wait_ready
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
    parser.add_argument("--compositor", required=True)
    parser.add_argument("--wallpaper", required=True)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--renderer", choices=["pixman", "gles2"], default="pixman")
    parser.add_argument("--refresh-rate", type=int, default=60)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="desktop-overview-") as directory:
        root = Path(directory)
        artifacts = args.artifacts or root / "artifacts"
        artifacts.mkdir(parents=True, exist_ok=True)
        runtime = root / "runtime"
        runtime.mkdir(mode=0o700)
        gtk_config = root / "config/gtk-3.0"
        gtk_config.mkdir(parents=True)
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
        for key in ["DISPLAY", "WAYLAND_DISPLAY"]:
            env.pop(key, None)
        env.update(
            XDG_RUNTIME_DIR=str(runtime),
            XDG_CONFIG_HOME=str(root / "config"),
            XDG_DATA_HOME=str(root / "data"),
            WLR_BACKENDS="headless",
            WLR_RENDERER=args.renderer,
            WLR_HEADLESS_OUTPUTS="1",
            NO_AT_BRIDGE="1",
            GTK_USE_PORTAL="0",
            GIO_USE_VFS="local",
            GSETTINGS_BACKEND="keyfile",
            G_DEBUG="fatal-criticals",
        )
        processes = Processes(artifacts, env)
        pointer = None

        def start(command, name, **extra):
            return processes.start(command, f"{name}.log", extra)

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

        binary = args.bin_dir / "desktop-zig"
        overview_command = [str(binary), "overview"]
        log_path = artifacts / "overview.log"

        def log():
            return log_path.read_text()

        def reopen():
            run(overview_command)
            time.sleep(0.6)

        try:
            compositor = start([args.compositor, "compositor-only"], "compositor")
            wait_for(
                lambda: (runtime / "wayland-0").exists(), "Compositor did not start"
            )
            env["WAYLAND_DISPLAY"] = "wayland-0"
            run(["wlr-randr", "--output", "HEADLESS-1", "--custom-mode", f"1728x1080@{args.refresh_rate}"])
            pointer = sp.Popen(
                [str(args.bin_dir / "desktop-pointer-fixture")],
                env=env,
                stdin=sp.PIPE,
                stdout=sp.PIPE,
                stderr=(artifacts / "pointer.log").open("w"),
                text=True,
            )
            processes.track(pointer)
            assert select.select([pointer.stdout], [], [], 5)[0], (
                "Virtual pointer did not start"
            )
            assert pointer.stdout.readline().strip() == "ready"
            panel_config = root / "panel.json"
            panel_config.write_text(
                '{"left":[],"center":[{"kind":"clock","name":"gnome-clock"}],"right":[]}'
            )
            overview = start(
                session_command(binary, root, args.wallpaper, panel_config),
                "overview", WAYLAND_DEBUG="client",
            )
            wait_ready(binary, env, overview)
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
                            str(args.bin_dir / "desktop-switcher-fixture"),
                            f"io.test.{app}",
                            title,
                        ],
                        f"window-{index}",
                        **extra,
                    )
                )
                time.sleep(0.2)
            run(overview_command)
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
            files_handle = re.search(
                r'(ext_foreign_toplevel_handle_v1#\d+)\.app_id\("io.test.Files"\)',
                log(),
            ).group(1)
            files_id = re.search(
                re.escape(files_handle) + r'\.identifier\("([^"]+)"\)', log()
            ).group(1)
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
            # Stage -> dash; End targets Show Applications regardless of the
            # number of running apps. Activating it returns focus to the grid.
            key("Tab")
            key("End")
            key("Return")
            shot("dash-keyboard-applications")
            key("Escape")
            # The running Terminal app remains a stable dock target even when
            # its window is behind another application.
            terminal_before = (artifacts / "window-2.log").read_text().splitlines()
            pointer_command("move 824 1018")
            time.sleep(0.4)
            run(["grim", "-s", "1", "-g", "680,920 370x160", str(artifacts / "dash-tooltip.png")])
            click(824, 1018)
            wait_for(
                lambda: len((artifacts / "window-2.log").read_text().splitlines()) > len(terminal_before),
                "Native dash did not activate the Terminal window",
            )
            reopen()
            click(828, 126)
            wait_for(
                lambda: '.workspace(1, "2", 1)' in log(),
                "Workspace thumbnail did not switch",
            )
            key("Return")
            assert overview.poll() is None
            first_workspace = log().count('.workspace(0, "1", 1)')
            click(756, 126)
            wait_for(
                lambda: log().count('.workspace(0, "1", 1)') > first_workspace,
                "Workspace click did not finish before keyboard navigation",
            )
            second_workspace = log().count('.workspace(1, "2", 1)')
            key("Page_Down")
            wait_for(
                lambda: log().count('.workspace(1, "2", 1)') > second_workspace,
                "Keyboard workspace navigation failed",
            )
            first_workspace = log().count('.workspace(0, "1", 1)')
            key("Page_Up")
            wait_for(
                lambda: log().count('.workspace(0, "1", 1)') > first_workspace,
                "Keyboard workspace navigation did not return before dragging",
            )
            pointer_command("move 1120 760")
            pointer_command("button 1")
            for x, y in [(1050, 600), (950, 400), (850, 200), (828, 126)]:
                pointer_command(f"move {x} {y}")
                time.sleep(0.05)
            pointer_command("button 0")
            wait_for(
                lambda: f'.window("{files_id}", 1,' in log(),
                "Dragging a window to another workspace failed",
            )
            # Exercise an actual input-method peer, rather than injecting a UI signal.
            ime = InputMethod(env)
            try:
                click(864, 62)
                ime.wait(lambda: ime.active, "Search did not enable native text input")
                ime.popup()
                ime.grab()
                key("a")
                ime.wait(lambda: len(ime.keys) >= 2, "IME keyboard grab did not receive press/release")
                assert ime.text == "", "Grabbed key leaked directly into the search query"
                ime.release()
                ime.preedit("とうきょう")
                time.sleep(.1)
                ime.roundtrip()
                assert ime.text == "", "Preedit changed the committed query"
                ime.commit("東京")
                ime.wait(lambda: ime.text == "東京", "Japanese IME commit did not reach search")
                ime.stale("ignored")
                assert ime.text == "東京", "Stale IME commit changed the query"
                ime.commit("Files", before=6)
                ime.wait(lambda: ime.text == "Files", "IME deletion/replacement failed")
                key("Escape")
                ime.wait(lambda: not ime.active, "Search focus loss did not deactivate IME")
            finally:
                ime.close()
            transient_ime = InputMethod(env)
            click(864, 62)
            transient_ime.wait(lambda: transient_ime.active, "Replacement IME did not activate")
            transient_ime.popup()
            transient_ime.socket.close()  # Disconnect with a live candidate surface.
            time.sleep(.1)
            key("Tab")  # Return to content without hiding the empty overview.
            assert compositor.poll() is None, "IME disconnect crashed the compositor"
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
            wait_for(
                lambda: len(re.findall(r"-> zwlr_layer_surface_v1#\d+\.destroy\(", log())) == maps,
                "Super did not hide the overview",
            )
            assert compositor.poll() is None
            overview_surfaces = re.findall(r'get_layer_surface\([^\n]*wl_surface#(\d+),[^\n]*"desktop-overview"', log())
            assert overview_surfaces and any(re.search(rf'wl_surface#{surface}\.frame\(', log()) for surface in overview_surfaces), "Overview did not request compositor frame callbacks"
            assert not re.search(r"CRITICAL|panic:|protocol error", log()), log()[
                -4000:
            ]
            print(
                "PASS: live captures, exact activation, idle cleanup, workspaces, drag, keyboard, native dash, tooltips, native IME, search, app grid, close and Super"
            )
        finally:
            processes.stop()


if __name__ == "__main__":
    main()
