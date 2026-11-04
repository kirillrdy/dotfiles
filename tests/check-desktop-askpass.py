"""Drive askpass with synthetic credentials on a private headless compositor."""
import argparse
import os
from pathlib import Path
import subprocess as sp
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True)
parser.add_argument("--wtype", default="wtype")
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="desktop-askpass-input-", dir="/tmp"))
print(f"Askpass input artifacts: {root}", flush=True)
(root / "runtime").mkdir(mode=0o700)
env = dict(os.environ, XDG_RUNTIME_DIR=str(root / "runtime"),
           XDG_CONFIG_HOME=str(root / "config"), XDG_CACHE_HOME=str(root / "cache"),
           DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-system-bus"),
           WLR_BACKENDS="headless", WLR_RENDERER="pixman", WLR_HEADLESS_OUTPUTS="1",
           GDK_BACKEND="wayland", GSETTINGS_BACKEND="memory")
for name in ("DISPLAY", "WAYLAND_DISPLAY", "DESKTOP_ZIG_INVOKED_AS"):
    env.pop(name, None)


def check(name, hint, keys, expected, status):
    child_env = dict(env, SSH_ASKPASS_PROMPT=hint, WAYLAND_DEBUG="client")
    path = root / (name + ".log")
    with path.open("w") as log:
        child = sp.Popen([args.binary, "askpass", "Synthetic prompt: 東京 <key> 100%"],
                         env=child_env, stdout=sp.PIPE, stderr=log)
        try:
            deadline = time.monotonic() + 10
            while 'set_title("SSH Authentication")' not in path.read_text():
                assert child.poll() is None, path.read_text()
                assert time.monotonic() < deadline, "Askpass did not map"
                time.sleep(0.02)
            sp.run([args.wtype, "-s", "300", *keys], env=env,
                   check=True, capture_output=True, timeout=10)
            output, _ = child.communicate(timeout=10)
            assert child.returncode == status, (name, child.returncode, path.read_text())
            assert output.decode() == expected, (name, output)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()


with (root / "compositor.log").open("w") as log:
    compositor = sp.Popen([args.binary, "compositor-only"], env=env, stdout=log, stderr=log)
    keyboard = None
    try:
        deadline = time.monotonic() + 10
        while not (root / "runtime/wayland-0").is_socket():
            assert compositor.poll() is None, (root / "compositor.log").read_text()
            assert time.monotonic() < deadline, "Private compositor did not start"
            time.sleep(0.02)
        env["WAYLAND_DISPLAY"] = str(root / "runtime/wayland-0")
        # Keep a keyboard present before windows map, as on a real desktop.
        keyboard = sp.Popen([args.wtype, "-s", "30000"], env=env,
                            stdout=sp.DEVNULL, stderr=sp.DEVNULL)
        time.sleep(0.1)
        assert keyboard.poll() is None, "Virtual keyboard did not start"
        check("password", "", ["native-東京🔑", "-k", "BackSpace", "-k", "Return"], "native-東京\n", 0)
        check("selection", "", ["old-secret", "-M", "ctrl", "a", "-m", "ctrl", "replacement-東京", "-k", "Return"], "replacement-東京\n", 0)
        check("cancel", "", ["unused", "-k", "Escape"], "", 1)
        check("confirm-deny", "confirm", ["-k", "Return"], "", 1)
        check("confirm-allow", "confirm", ["-k", "Tab", "-k", "Return"], "yes\n", 0)
        check("information", "none", ["-k", "Return"], "", 0)
        print("PASS native askpass keyboard input, Unicode deletion, selection replacement, cancellation, default denial and explicit confirmation", flush=True)
    finally:
        if keyboard is not None:
            keyboard.terminate()
            keyboard.wait(timeout=5)
        compositor.terminate()
        compositor.wait(timeout=5)
