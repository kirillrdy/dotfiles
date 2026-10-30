"""Exercise the real Zig compositor with GTK windows and a test-only lock client."""

import argparse
import os
import pathlib
import select
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bin-dir", type=pathlib.Path, required=True)
parser.add_argument("--wtype", required=True)
args = parser.parse_args()
root = pathlib.Path(tempfile.mkdtemp(prefix="desktop-compositor-integration-"))
print(root, flush=True)
env = dict(
    os.environ,
    XDG_RUNTIME_DIR=str(root / "runtime"),
    XDG_CACHE_HOME=str(root / "cache"),
    WLR_BACKENDS="headless",
    WLR_HEADLESS_OUTPUTS="2",
    WLR_RENDERER="pixman",
    WAYLAND_DISPLAY="wayland-0",
    GDK_BACKEND="wayland",
    GSETTINGS_BACKEND="memory",
    NO_AT_BRIDGE="1",
    GTK_USE_PORTAL="0",
)
(root / "runtime").mkdir(mode=0o700)
(root / "cache").mkdir()
bin = str(args.bin_dir.resolve()) + "/"
wtype = args.wtype
children = []
logs = []


def start(name, args):
    f = (root / (name + ".log")).open("w")
    logs.append(f)
    process = subprocess.Popen(args, env=env, stdout=f, stderr=f)
    children.append(process)
    return process


def run(args):
    result = subprocess.run(
        args,
        check=False,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=15,
    )
    if result.returncode:
        raise RuntimeError(str(args) + "\n" + result.stdout)
    return result.stdout


def probe(*args):
    return run([bin + "desktop-compositor-fixture", *args])


def wait(test, label):
    for _ in range(100):
        if test():
            return
        if server.poll() is not None:
            raise RuntimeError(
                "compositor exited: " + (root / "server.log").read_text()
            )
        time.sleep(0.05)
    raise RuntimeError("timeout: " + label)


def switcher_checks():
    # Keep a keyboard on the seat while each short-lived wtype sends a chord.
    start("keyboard-seat", [wtype, "-s", "60000"])
    windows = {}

    def focused():
        events = []
        for title in windows:
            for line in (root / (title + ".log")).read_text().splitlines():
                stamp, _, name = line.partition(" ")
                if stamp.isdigit():
                    events.append((int(stamp), name))
        return max(events, default=(0, ""))[1]

    def keys(*chord):
        run([wtype, "-s", "50", *chord])

    for app, title in [("Browser", "Browser 1"), ("Browser", "Browser 2"), ("Terminal", "Terminal"), ("Files", "Files")]:
        windows[title] = start(title, [bin + "labwc-switcher-fixture", "io.test." + app, title])
        wait(lambda: focused() == title, "focus " + title)
    held = start("switcher-held", [wtype, "-M", "alt", "-k", "Tab", "-k", "Tab", "-s", "1200", "-m", "alt"])
    time.sleep(0.6)
    assert focused() == "Files", "Alt-Tab changed focus before Alt release"
    held.wait(timeout=5)
    wait(lambda: focused() == "Browser 2", "grouped application selection")
    keys("-M", "alt", "-M", "shift", "-k", "Tab", "-m", "shift", "-m", "alt")
    wait(lambda: focused() == "Terminal", "reverse app selection")
    keys("-M", "alt", "-k", "Tab", "-k", "Escape", "-m", "alt")
    assert focused() == "Terminal", "Escape did not cancel selection"
    keys("-M", "alt", "-k", "Tab", "-k", "Down", "-k", "Right", "-m", "alt")
    wait(lambda: focused() == "Browser 1", "application window selection")
    keys("-M", "alt", "-k", "grave", "-m", "alt")
    wait(lambda: focused() == "Browser 2", "Alt-grave")
    keys("-M", "alt", "-k", "Tab", "-k", "grave", "-m", "alt")
    wait(lambda: focused() == "Terminal", "Alt-grave uses the selected application")
    keys("-M", "alt", "-k", "Tab", "-k", "Down", "-k", "Right", "-k", "Up", "-k", "Right", "-k", "Return", "-m", "alt")
    wait(lambda: focused() == "Files", "return from window selection to apps and confirm")
    closing = start("switcher-close", [wtype, "-M", "alt", "-k", "Tab", "-s", "1200", "-m", "alt"])
    time.sleep(0.5)
    windows["Terminal"].terminate()
    windows["Terminal"].wait(timeout=5)
    closing.wait(timeout=5)
    wait(lambda: focused() == "Browser 2", "selected window closed during switching")
    for title, process in windows.items():
        if title != "Browser 1" and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
    wait(lambda: focused() == "Browser 1", "last window")
    keys("-M", "alt", "-k", "Tab", "-m", "alt")
    assert focused() == "Browser 1"
    windows["Browser 1"].terminate()
    windows["Browser 1"].wait(timeout=5)
    keys("-M", "alt", "-k", "Tab", "-m", "alt")
    assert server.poll() is None, "switching with no windows crashed"
    print("application grouping, window navigation, cancellation, confirmation and closing during Alt-Tab PASS", flush=True)


try:
    server = start("server", [bin + "desktop-zig", "compositor-only"])
    wait(lambda: (root / "runtime/wayland-0").exists(), "socket")
    switcher_checks()
    first = start(
        "first", [bin + "labwc-switcher-fixture", "com.dotfiles.First", "First"]
    )
    second = start(
        "second", [bin + "labwc-switcher-fixture", "com.dotfiles.Second", "Second"]
    )
    wait(lambda: "First" in probe("list") and "Second" in probe("list"), "windows")
    print(probe("capture"), flush=True)
    assert "workspace 0/4" in probe("list")
    run([bin + "desktop-zig", "output", "--output", "HEADLESS-1", "--scale", "1.25"])
    print("output scale applied", flush=True)
    probe("move", "First", "1")
    assert "window First workspace 1" in probe("list")
    # Hidden windows must still produce real capture buffers.
    print("hidden capture:", probe("capture"), flush=True)
    probe("activate", "First")
    assert "workspace 1/4" in probe("list")
    probe("workspace", "0")
    assert "workspace 0/4" in probe("list")
    run([wtype, "-s", "100", "-M", "alt", "-k", "F4", "-m", "alt"])
    wait(lambda: second.poll() is not None, "Alt-F4")
    probe("activate", "First")
    lock_log = (root / "lock.log").open("w")
    logs.append(lock_log)
    r, w = os.pipe()
    locker = subprocess.Popen(
        [bin + "desktop-lock-fixture", "--ready-fd", str(w)],
        env=env,
        pass_fds=(w,),
        stdout=lock_log,
        stderr=lock_log,
    )
    children.append(locker)
    os.close(w)
    assert select.select([r], [], [], 10)[0], "lock readiness timeout"
    assert os.read(r, 1) == b"1"
    os.close(r)
    print("lock ready", flush=True)
    run([wtype, "-s", "100", "-M", "alt", "-k", "F4", "-m", "alt"])
    assert first.poll() is None, "shortcut escaped lock"
    run([wtype, "-s", "100", "incorrect", "-k", "Return"])
    time.sleep(2)
    assert locker.poll() is None, "wrong password unlocked"
    run([wtype, "-s", "100", "fixture-password", "-k", "Return"])
    locker.wait(timeout=10)
    assert locker.returncode == 0
    print("authenticated unlock passed", flush=True)
    # Crash the locker: desktop must stay hidden and accept a replacement lock.
    r, w = os.pipe()
    crashed = subprocess.Popen(
        [bin + "desktop-lock-fixture", "--ready-fd", str(w)],
        env=env,
        pass_fds=(w,),
        stdout=lock_log,
        stderr=lock_log,
    )
    children.append(crashed)
    os.close(w)
    assert select.select([r], [], [], 10)[0] and os.read(r, 1) == b"1"
    os.close(r)
    crashed.kill()
    crashed.wait()
    time.sleep(0.1)
    run([wtype, "-s", "100", "-M", "alt", "-k", "F4", "-m", "alt"])
    assert first.poll() is None
    r, w = os.pipe()
    replacement_log = (root / "replacement-lock.log").open("w")
    logs.append(replacement_log)
    replacement = subprocess.Popen(
        [bin + "desktop-lock-fixture", "--ready-fd", str(w)],
        env=env,
        pass_fds=(w,),
        stdout=replacement_log,
        stderr=replacement_log,
    )
    children.append(replacement)
    os.close(w)
    assert select.select([r], [], [], 10)[0] and os.read(r, 1) == b"1"
    os.close(r)
    run([wtype, "-s", "100", "fixture-password", "-k", "Return"])
    replacement.wait(timeout=10)
    assert replacement.returncode == 0
    print("crashed-lock isolation and recovery passed", flush=True)
    probe("close", "First")
    first.wait(timeout=5)
    assert not any("window " in line for line in probe("list").splitlines())
    print("window lifecycle, workspaces, capture, keyboard, lock PASS", flush=True)
finally:
    for child in reversed(children):
        if child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    for f in logs:
        f.close()
    print((root / "server.log").read_text()[-5000:], flush=True)
