"""Check native display scaling against two isolated headless Labwc outputs.

wlr-randr is an independent test oracle, not a desktop runtime dependency.
"""
import argparse
import json
import os
import socket
import struct
import threading
from pathlib import Path
import subprocess as sp
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True)
parser.add_argument("--compositor", default="labwc")
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="desktop-output-check-", dir="/tmp"))
print(f"Artifacts: {root}", flush=True)
(root / "runtime").mkdir(mode=0o700)
config = root / "config"
config.mkdir()
(config / "rc.xml").write_text("<labwc_config />")
(config / "autostart").write_text("")
(config / "environment").write_text("LABWC_UPDATE_ACTIVATION_ENV=false\n")
env = dict(os.environ)
for key in ("DISPLAY", "WAYLAND_DISPLAY", "LABWC_PID", "DESKTOP_ZIG_INVOKED_AS"):
    env.pop(key, None)
env.update(XDG_RUNTIME_DIR=str(root / "runtime"), WLR_BACKENDS="headless",
           WLR_RENDERER="pixman", WLR_HEADLESS_OUTPUTS="2", LABWC_UPDATE_ACTIVATION_ENV="false")


def run(command, check=True):
    return sp.run(command, env=env, capture_output=True, text=True, check=check, timeout=9)


def state():
    return {head["name"]: head for head in json.loads(run(["wlr-randr", "--json"]).stdout)}


def scale(name, value, error=None):
    result = run([args.binary, "output", "--output", name, "--scale", value], check=False)
    if error:
        assert result.returncode != 0 and error in result.stderr, result
    else:
        assert result.returncode == 0, result.stderr


with (root / "compositor.log").open("w") as log:
    compositor = sp.Popen([args.compositor, "-C", str(config)], env=env, stdout=log, stderr=sp.STDOUT)
try:
    deadline = time.monotonic() + 10
    while True:
        sockets = list((root / "runtime").glob("wayland-*"))
        sockets = [path for path in sockets if not path.name.endswith(".lock")]
        if sockets:
            env["WAYLAND_DISPLAY"] = sockets[0].name
            probe = run(["wlr-randr", "--json"], check=False)
            if probe.returncode == 0 and len(json.loads(probe.stdout)) == 2:
                break
        assert compositor.poll() is None, (root / "compositor.log").read_text()
        assert time.monotonic() < deadline, "compositor did not start"
        time.sleep(0.03)
    run(["wlr-randr", "--output", "HEADLESS-2", "--pos", "1400,70", "--transform", "90", "--scale", "1.25"])
    before = state()
    scale("HEADLESS-1", "1.625")
    after = state()
    assert after["HEADLESS-1"]["scale"] == 1.625, after
    assert before["HEADLESS-2"] == after["HEADLESS-2"], (before, after)
    expected = dict(before["HEADLESS-1"], scale=1.625)
    assert after["HEADLESS-1"] == expected, (expected, after)
    scale("HEADLESS-1", "1.625")  # Reapplying the startup command is harmless.
    assert state() == after
    for value in ("0", "-1", "nan", "inf", "8388608", "bogus"):
        scale("HEADLESS-1", value, "InvalidOutputScale")
    scale("missing-output", "1.5", "OutputNotFound")
    assert state() == after
    run(["wlr-randr", "--output", "HEADLESS-2", "--off"])
    disabled = state()["HEADLESS-2"]
    scale("HEADLESS-2", "1.5", "OutputDisabled")
    scale("HEADLESS-1", "1.25")
    assert state()["HEADLESS-2"] == disabled
    assert state()["HEADLESS-1"]["scale"] == 1.25
    print("PASS fractional scaling, state preservation, disabled outputs, and invalid requests", flush=True)
finally:
    compositor.terminate()
    try:
        compositor.wait(timeout=5)
    except sp.TimeoutExpired:
        compositor.kill()
        compositor.wait()

# A silent compositor must not leave session startup waiting indefinitely.
def fake_server(mode):
    path = root / "runtime" / "fake-wayland"
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(path))
    listener.listen(1)
    def serve():
        try:
            conn, _ = listener.accept()
            with conn:
                conn.settimeout(8)
                pending = b""
                registry = manager = configuration = None
                def string(value):
                    data = value.encode() + b"\0"
                    return struct.pack("=I", len(data)) + data + b"\0" * (-len(data) % 4)
                def event(obj, opcode, payload):
                    conn.sendall(struct.pack("=II", obj, (8 + len(payload)) << 16 | opcode) + payload)
                while True:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    pending += chunk
                    while len(pending) >= 8:
                        obj, header = struct.unpack_from("=II", pending)
                        size, opcode = header >> 16, header & 0xffff
                        if len(pending) < size:
                            break
                        message, pending = pending[:size], pending[size:]
                        if obj == 1 and opcode == 1:
                            registry, = struct.unpack_from("=I", message, 8)
                            if mode in ("rejected", "cancelled"):
                                event(registry, 0, struct.pack("=I", 42) + string("zwlr_output_manager_v1") + struct.pack("=I", 1))
                        if obj == registry and opcode == 0:
                            manager, = struct.unpack_from("=I", message, len(message) - 4)
                            head = 0xff000000
                            event(manager, 0, struct.pack("=I", head))
                            event(head, 0, string("HEADLESS-1"))
                            event(head, 4, struct.pack("=i", 1))
                            event(manager, 1, struct.pack("=I", 7))
                        if obj == manager and opcode == 0:
                            configuration, = struct.unpack_from("=I", message, 8)
                        if obj == configuration and opcode == 2:
                            event(configuration, 1 if mode == "rejected" else 2, b"")
                        # wl_display.sync: finish registry enumeration.
                        if obj == 1 and opcode == 0 and mode != "silent":
                            callback, = struct.unpack_from("=I", message, 8)
                            conn.sendall(struct.pack("=III", callback, 12 << 16, 0))
        finally:
            listener.close()
    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    env["WAYLAND_DISPLAY"] = str(path)
    try:
        expected = {"unsupported": "OutputManagerUnavailable", "silent": "OutputConfigurationTimedOut",
                    "rejected": "OutputConfigurationRejected", "cancelled": "OutputConfigurationCancelled"}[mode]
        scale("HEADLESS-1", "1.625", expected)
    finally:
        thread.join(timeout=9)
        assert not thread.is_alive()
        path.unlink()


fake_server("unsupported")
fake_server("silent")
fake_server("rejected")
fake_server("cancelled")
env["WAYLAND_DISPLAY"] = "nonexistent-wayland-socket"
scale("HEADLESS-1", "1.625", "WaylandUnavailable")
print("PASS missing protocol, unavailable compositor, bounded timeout, rejection, and cancellation", flush=True)
