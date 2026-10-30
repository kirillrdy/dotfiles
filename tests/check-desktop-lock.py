"""Exercise session locking on an isolated, two-output headless Labwc compositor."""
import argparse
import os
from pathlib import Path
import signal
import subprocess as sp
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--fixture", required=True)
parser.add_argument("--binary", required=True)
parser.add_argument("--compositor", default="desktop-zig")
parser.add_argument("--wtype", default="wtype")
parser.add_argument("--randr", default="wlr-randr")
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="desktop-lock-check-", dir="/tmp"))
print(f"Artifacts: {root}", flush=True)
(root / "runtime").mkdir(mode=0o700)
config = root / "config"
config.mkdir()
(config / "rc.xml").write_text("<labwc_config><keyboard><default /></keyboard></labwc_config>")
(config / "autostart").write_text("")
(config / "environment").write_text("LABWC_UPDATE_ACTIVATION_ENV=false\n")
env = dict(os.environ)
for name in ("DISPLAY", "WAYLAND_DISPLAY", "LABWC_PID", "DESKTOP_ZIG_INVOKED_AS"):
    env.pop(name, None)
env.update(
    XDG_RUNTIME_DIR=str(root / "runtime"),
    XDG_CONFIG_HOME=str(root / "config-home"),
    XDG_CACHE_HOME=str(root / "cache"),
    WLR_BACKENDS="headless", WLR_RENDERER="pixman", WLR_HEADLESS_OUTPUTS="2",
    LABWC_UPDATE_ACTIVATION_ENV="false", WAYLAND_DEBUG="client",
    DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-system-bus"),
)
processes = []

def start(command, name):
    with (root / name).open("w") as log:
        process = sp.Popen(command, env=env, stdout=log, stderr=log)
    processes.append(process)
    return process

def wait_until(predicate, message, timeout=10):
    deadline = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < deadline, message
        time.sleep(0.03)

def text(name):
    return (root / name).read_text(errors="replace")

def run(command):
    return sp.run(command, env=env, capture_output=True, timeout=10, check=True)

def type_password(password):
    # One virtual keyboard per invocation; its enter/leave events also test focus handling.
    run([args.wtype, "-d", "10", password, "-k", "Return"])

try:
    compositor = start([args.compositor, "compositor-only"], "compositor.log")
    wait_until(lambda: list((root / "runtime").glob("wayland-*.lock")), "No Wayland socket")
    env["WAYLAND_DISPLAY"] = next((root / "runtime").glob("wayland-*.lock")).stem
    locker = start([args.fixture], "lock.log")
    wait_until(lambda: "ext_session_lock_v1" in text("lock.log") and ".locked()" in text("lock.log"), "Lock not acquired")
    wait_until(lambda: text("lock.log").count(".ack_configure(") >= 2, "Both outputs were not configured")
    run([args.randr, "--output", "HEADLESS-2", "--off"])
    run([args.randr, "--output", "HEADLESS-2", "--on"])
    wait_until(lambda: text("lock.log").count(".ack_configure(") >= 3, "Re-enabled output was not locked")
    type_password("incorrect")
    wait_until(lambda: "fixture-auth: rejected" in text("lock.log"), "Wrong password did not reach authenticator")
    assert locker.poll() is None
    assert "unlock_and_destroy" not in text("lock.log")
    type_password("fixture-password")
    time.sleep(0.1)
    assert locker.poll() is None, "Retry delay accepted input too early"
    time.sleep(1.7)  # The lock client enforces a retry delay independently of PAM.
    locker.send_signal(signal.SIGTERM)
    time.sleep(0.1)
    assert locker.poll() is None, "SIGTERM terminated the locker"
    # A second client must not acquire a lock or report successful readiness.
    rejected = sp.run([args.fixture, "--daemonize"], env=env, capture_output=True, timeout=10)
    assert rejected.returncode != 0, rejected.stderr
    type_password("fixture-password")
    assert locker.wait(timeout=10) == 0, text("lock.log")
    assert text("lock.log").count("unlock_and_destroy()") == 1
    # Readiness must follow locked, and daemonized locking must also unlock normally.
    daemon = start([args.fixture, "--daemonize"], "daemon.log")
    assert daemon.wait(timeout=10) == 0, text("daemon.log")
    assert ".locked()" in text("daemon.log"), "Daemon returned before compositor lock confirmation"
    wait_until(lambda: ".modifiers(" in text("daemon.log"), "Daemon keyboard did not receive focus")
    type_password("fixture-password")
    wait_until(lambda: "unlock_and_destroy()" in text("daemon.log"), "Daemon did not unlock")
    # Exercise production entry point without sending any credentials to real PAM.
    production = start([args.binary, "lock"], "production.log")
    wait_until(lambda: ".locked()" in text("production.log"), "Production command did not lock")
    production.kill()
    production.wait(timeout=5)
    assert "unlock_and_destroy" not in text("production.log"), "Crash unlocked the session"
    # Labwc permits another locker to recover an abandoned lock; authenticate it.
    recovery = start([args.fixture], "recovery.log")
    wait_until(lambda: ".locked()" in text("recovery.log"), "Abandoned lock could not be recovered")
    wait_until(lambda: ".modifiers(" in text("recovery.log"), "Recovery keyboard did not receive focus")
    type_password("fixture-password")
    assert recovery.wait(timeout=10) == 0, text("recovery.log")
    print("PASS: multiple outputs, output disable/enable, wrong password, successful unlock, signals, duplicate rejection, daemon readiness, production CLI and crash recovery")
finally:
    # Stop the isolated compositor first; daemonized children exit on disconnect.
    if "compositor" in locals() and compositor.poll() is None:
        compositor.terminate()
        try:
            compositor.wait(timeout=5)
        except sp.TimeoutExpired:
            compositor.kill()
            compositor.wait()
    for process in reversed(processes):
        if process.poll() is None:
            process.kill()
            process.wait()
