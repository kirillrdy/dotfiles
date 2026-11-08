"""Exercise the unified shell on two headless Wayland outputs under dbus-run-session."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess as sp
import tempfile
import time
import sys
sys.dont_write_bytecode = True
from audio_server import AudioServer
from session_fixture import Processes

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True, type=Path)
parser.add_argument("--compositor", default="desktop-zig")
parser.add_argument("--panel-config", type=Path)
parser.add_argument("--panel-style", type=Path)
parser.add_argument("--notification-style", type=Path)
parser.add_argument("--osd-style", type=Path)
args = parser.parse_args()
binary = str(args.binary.resolve())
root = Path(tempfile.mkdtemp(prefix="desktop-shell-check-", dir="/tmp"))
print(f"Artifacts: {root}", flush=True)
(root / "runtime").mkdir(mode=0o700)
# GdkPixbuf's built-in PPM decoder needs no external image module.
(root / "wallpaper.ppm").write_bytes(b"P6\n2 2\n255\n" + bytes([20, 40, 80]) * 4)
(root / "panel.json").write_text(json.dumps({
    "left": [{"name": "gnome-activities", "kind": "activities"}],
    "center": [{"name": "gnome-clock", "kind": "clock"}],
    "right": [
        {"name": "gnome-monitors", "kind": "monitors", "source": "monitors"},
        {"name": "gnome-codex", "source": "codex"},
        {"name": "gnome-disk", "source": "disk"},
        {"name": "gnome-status", "source": "status"},
    ],
}))
env = dict(os.environ)
for name in ("DISPLAY", "WAYLAND_DISPLAY", "DESKTOP_ZIG_INVOKED_AS"):
    env.pop(name, None)
env.update(
    XDG_RUNTIME_DIR=str(root / "runtime"),
    XDG_CONFIG_HOME=str(root / "config-home"),
    XDG_CACHE_HOME=str(root / "cache"),
    GSETTINGS_BACKEND="memory", GDK_BACKEND="wayland",
    WLR_BACKENDS="headless", WLR_RENDERER="pixman", WLR_HEADLESS_OUTPUTS="2",
    NO_AT_BRIDGE="1", GTK_USE_PORTAL="0",
    GIO_USE_VFS="local", WB_PANEL_DEMO="1", G_DEBUG="fatal-criticals",
    WAYLAND_DEBUG="client",
    # Never register an agent or query services on the real system bus.
    DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-system-bus"),
)
(root / "tools").mkdir()
for name, body in {
    "nmcli": 'exit 0',
}.items():
    tool = root / "tools" / name
    tool.write_text(f"#!{shutil.which("sh")}\n" + body + "\n")
    tool.chmod(0o755)
env["PATH"] = str(root / "tools") + os.pathsep + env["PATH"]
processes = Processes(root, env)
start = processes.start
audio = AudioServer(root, env)


def run(command, ok=True):
    result = sp.run(command, env=env, capture_output=True, text=True, timeout=15)
    if ok:
        assert result.returncode == 0, (command, result.stderr)
    return result


def wait_for(check, description):
    deadline = time.monotonic() + 15
    while not check():
        assert time.monotonic() < deadline, description
        time.sleep(0.05)


def shell_log():
    return (root / "shell.log").read_text()


def check_shell():
    assert shell.poll() is None, shell_log()[-8000:]
    assert not re.search(r"CRITICAL|assertion|panic:|Segmentation|backend failed", shell_log()), shell_log()[-8000:]


def owner_pid(name):
    output = run(["gdbus", "call", "--session", "--dest", "org.freedesktop.DBus",
                  "--object-path", "/org/freedesktop/DBus", "--method",
                  "org.freedesktop.DBus.GetConnectionUnixProcessID", name]).stdout
    return int(re.search(r"uint32 (\d+)", output)[1])


try:
    audio.start()
    compositor = start([args.compositor, "compositor-only"], "compositor.log")
    wait_for(lambda: (root / "runtime/wayland-0").exists(), "compositor socket")
    env["WAYLAND_DISPLAY"] = "wayland-0"
    assert run([binary, "ping"], ok=False).returncode != 0, "client must not start a desktop"
    command = [binary, "serve", str(root / "wallpaper.ppm"),
               str(args.panel_config or root / "panel.json")]
    shell = start(command, "shell.log")
    wait_for(lambda: run([binary, "ping"], ok=False).returncode == 0, "shell ready")
    wait_for(lambda: shell_log().count('"desktop-panel"') >= 2, "panel on both outputs")
    wait_for(lambda: shell_log().count('"desktop-wallpaper"') >= 2, "wallpaper on both outputs")
    wait_for(lambda: '.get_idle_notification(' in shell_log(), "native idle notification")
    assert owner_pid("org.dotfiles.Desktop") == shell.pid
    wait_for(lambda: "org.freedesktop.Notifications" in run([
        "gdbus", "call", "--session", "--dest", "org.freedesktop.DBus", "--object-path",
        "/org/freedesktop/DBus", "--method", "org.freedesktop.DBus.ListNames"]).stdout,
        "notification service")
    assert owner_pid("org.freedesktop.Notifications") == shell.pid
    assert run(command, ok=False).returncode != 0, "second serve must not create another shell"
    assert run([binary, "invalid-command"], ok=False).returncode != 0
    run([binary, "refresh", "codex"])
    run([binary, "refresh", "status"])
    def media_ready():
        run([binary, "volume", "up"])
        return '\"desktop-osd\"' in shell_log()
    wait_for(media_ready, "native audio and media overlay ready")
    for kind, action in (("volume", "up"), ("volume", "mute"),
                         ("microphone", "mute"), ("brightness", "down")):
        run([binary, kind, action])
    wait_for(lambda: '"desktop-osd"' in shell_log(), "media overlay")
    for mode in ("network", "sound", "network"):
        run([binary, "settings", mode])
        check_shell()
    for _ in range(4):
        run([binary, "overview"])
        check_shell()
    run(["gdbus", "call", "--session", "--dest", "org.freedesktop.Notifications",
         "--object-path", "/org/freedesktop/Notifications", "--method",
         "org.freedesktop.Notifications.Notify", "Shell test", "0", "", "One process",
         "Notifications share the shell", "[]", "{}", "1000"])
    time.sleep(1)
    check_shell()
    # No producer or desktop service children; collectors run in worker threads.
    children = Path(f"/proc/{shell.pid}/task/{shell.pid}/children").read_text().split()
    for child in children:
        cmdline = Path(f"/proc/{child}/cmdline").read_bytes().replace(b"\0", b" ")
        assert b"desktop-zig" not in cmdline, cmdline
    shell.send_signal(signal.SIGTERM)
    assert shell.wait(timeout=15) == 0, shell_log()[-8000:]
    assert not re.search(r"CRITICAL|assertion|panic:|Segmentation|backend failed", shell_log()), shell_log()[-8000:]
    assert compositor.poll() is None, "shell shutdown must leave compositor running"
    # A clean restart must reclaim the same service names.
    shell = start(command, "restart.log")
    def restarted():
        assert shell.poll() is None, (root / "restart.log").read_text()[-8000:]
        return run([binary, "ping"], ok=False).returncode == 0
    wait_for(restarted, "restarted shell ready")
    assert owner_pid("org.dotfiles.Desktop") == shell.pid
    shell.terminate()
    assert shell.wait(timeout=15) == 0, (root / "restart.log").read_text()[-8000:]
    print("desktop-zig: two outputs, shared services, command forwarding, settings, media keys, overview, "
          "notifications, shutdown and restart passed")
finally:
    audio.stop()
    processes.stop(timeout=10)
