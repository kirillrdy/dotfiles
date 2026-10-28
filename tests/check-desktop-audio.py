"""Exercise native audio against private PipeWire/WirePlumber and virtual nodes only."""
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import sys
sys.dont_write_bytecode = True
import subprocess as sp
import tempfile
import threading
import time
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--fixture", required=True)
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="desktop-audio-check-", dir="/tmp"))
print(f"Artifacts: {root}", flush=True)
(root / "runtime").mkdir(mode=0o700)
from audio_server import AudioServer
AudioServer.configure(root, root / "config")
env = dict(os.environ, XDG_RUNTIME_DIR=str(root / "runtime"), XDG_CONFIG_HOME=str(root / "config"),
           XDG_STATE_HOME=str(root / "state"), PIPEWIRE_REMOTE="pipewire-0", PIPEWIRE_DEBUG="1",
           G_DEBUG="fatal-criticals", GSETTINGS_BACKEND="memory",
           PULSE_SERVER="unix:" + str(root / "runtime/pulse/native"), PULSE_RUNTIME_PATH=str(root / "runtime/pulse"))
if "DBUS_SESSION_BUS_ADDRESS" in env:
    env["DBUS_SYSTEM_BUS_ADDRESS"] = env["DBUS_SESSION_BUS_ADDRESS"]
for key in ("PIPEWIRE_RUNTIME_DIR", "PIPEWIRE_CONFIG_DIR", "WIREPLUMBER_CONFIG_DIR", "WIREPLUMBER_DATA_DIR", "DESKTOP_ZIG_INVOKED_AS"):
    env.pop(key, None)
processes = []
updates = queue.Queue()


def start(command, log, stdout=None):
    with (root / log).open("w") as output:
        process = sp.Popen(command, env=env, stdout=stdout or output, stderr=output, text=True)
    processes.append(process)
    return process


def run(command, check=True):
    return sp.run(command, env=env, check=check, capture_output=True, text=True, timeout=12)


def native(*command, check=True):
    return run([args.fixture, *command], check)


def wait(check, description, timeout=12):
    deadline = time.monotonic() + timeout
    while not check():
        assert time.monotonic() < deadline, description
        time.sleep(0.03)


def watch_updates(process):
    for line in process.stdout:
        with (root / "watcher.jsonl").open("a") as log:
            log.write(line)
        updates.put(json.loads(line))


def expect(check, description, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = updates.get(timeout=0.05)
        except queue.Empty:
            assert watcher.poll() is None, (root / "watcher.log").read_text()
            continue
        if check(value):
            return value
    raise AssertionError(description)


def node_name(node):
    value = node["name"]
    return bytes(value).split(b"\0")[0].decode() if isinstance(value, list) else value.split("\0")[0]


try:
    native("dispose")
    watcher = start([args.fixture, "watch"], "watcher.log", stdout=sp.PIPE)
    threading.Thread(target=watch_updates, args=(watcher,), daemon=True).start()
    expect(lambda s: not s["ready"], "unavailable server should be reported")
    pipewire = start(["pipewire", "-c", str(root / "pipewire.conf")], "pipewire.log")
    wait(lambda: (root / "runtime/pipewire-0").exists(), "private PipeWire socket")
    wireplumber = start(["wireplumber"], "wireplumber.log")
    first = expect(lambda s: len(s["nodes"]) == 3 and any(n["is_default"] and n["class"] == "output" for n in s["nodes"]), "initial native nodes")
    nodes = {node_name(node): node["id"] for node in first["nodes"]}
    speakers = str(nodes["fixture-speakers"])
    headphones = str(nodes["fixture-headphones"])
    microphone = str(nodes["fixture-microphone"])
    native("set", speakers, "default")
    native("set", speakers, "volume", "42")
    assert "0.42" in run(["wpctl", "get-volume", speakers]).stdout
    native("set", speakers, "mute", "1")
    assert "MUTED" in run(["wpctl", "get-volume", speakers]).stdout
    native("set", "@DEFAULT_AUDIO_SINK@", "step", "5")
    oracle = run(["wpctl", "get-volume", speakers]).stdout
    assert "0.47" in oracle and "MUTED" not in oracle, oracle
    native("set", speakers, "volume", "200")
    assert "1.00" in run(["wpctl", "get-volume", speakers]).stdout
    native("set", speakers, "step", "5")
    assert "1.00" in run(["wpctl", "get-volume", speakers]).stdout
    native("set", speakers, "volume", "-5")
    assert "0.00" in run(["wpctl", "get-volume", speakers]).stdout
    native("set", microphone, "mute", "1")
    assert "MUTED" in run(["wpctl", "get-volume", microphone]).stdout
    native("set", "@DEFAULT_AUDIO_SOURCE@", "toggle")
    assert "MUTED" not in run(["wpctl", "get-volume", microphone]).stdout
    invalid = native("set", speakers, "volume", "nan", check=False)
    assert invalid.returncode != 0 and "InvalidVolume" in invalid.stderr, invalid
    absent = native("set", "4294967294", "volume", "25", check=False)
    assert absent.returncode != 0 and "AudioUnavailable" in absent.stderr, absent
    run(["wpctl", "set-volume", speakers, "0.38"])
    expect(lambda s: any(n["id"] == int(speakers) and n["state"] and abs(n["state"]["percent"] - 38) < 0.01 for n in s["nodes"]), "external volume updates are pushed")
    native("burst")
    assert "0.40" in run(["wpctl", "get-volume", speakers]).stdout
    native("cancel")
    print("PASS native volume, mute, defaults, limits, errors, external changes, and cancellation", flush=True)
    sound = root / "feedback.wav"
    with wave.open(str(sound), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(48000)
        wav.writeframes(b"\0\0" * 96000)
    native("feedback", str(sound))
    print("PASS native feedback playback without overlap", flush=True)
    native("ui")
    print("PASS native quick-settings and sound-settings widgets", flush=True)
    # Destroy a node through an independent PipeWire client and observe its removal.
    run(["pw-cli", "destroy", headphones])
    expect(lambda s: all(n["id"] != int(headphones) for n in s["nodes"]), "removed nodes disappear")
    wireplumber.terminate()
    wireplumber.wait(timeout=5)
    pipewire.terminate()
    pipewire.wait(timeout=5)
    expect(lambda s: not s["ready"] and not s["nodes"], "disconnection clears stale nodes")
    pipewire = start(["pipewire", "-c", str(root / "pipewire.conf")], "pipewire-restart.log")
    wait(lambda: (root / "runtime/pipewire-0").exists(), "restarted PipeWire socket")
    wireplumber = start(["wireplumber"], "wireplumber-restart.log")
    expect(lambda s: s["ready"] and len(s["nodes"]) == 3 and any(n["state"] for n in s["nodes"]), "native client reconnects")
    watcher.send_signal(signal.SIGTERM)
    assert watcher.wait(timeout=5) == 0, (root / "watcher.log").read_text()
    print("PASS native hotplug, server restart, reconnection and shutdown", flush=True)
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except sp.TimeoutExpired:
                process.kill()
                process.wait()
