"""Private PipeWire/WirePlumber with virtual devices; CLI tools are independent test oracles."""
import os
from pathlib import Path
import signal
import subprocess as sp
import time

WP_CONFIG = """
wireplumber.profiles = { main = {
  monitor.alsa = disabled
  monitor.alsa-midi = disabled
  monitor.bluez = disabled
  monitor.v4l2 = disabled
  monitor.libcamera = disabled
  support.logind = disabled
} }
"""
PW_CONFIG = """
context.properties = { core.daemon = true core.name = pipewire-0 support.dbus = false
  default.clock.rate = 48000 default.clock.quantum = 256 }
context.spa-libs = { audio.convert.* = audioconvert/libspa-audioconvert
  support.* = support/libspa-support audiotestsrc = audiotestsrc/libspa-audiotestsrc }
context.modules = [
  { name = libpipewire-module-protocol-native }
  { name = libpipewire-module-access args = { access.force = unrestricted } }
  { name = libpipewire-module-metadata }
  { name = libpipewire-module-spa-node-factory }
  { name = libpipewire-module-client-node }
  { name = libpipewire-module-adapter }
  { name = libpipewire-module-link-factory }
  { name = libpipewire-module-session-manager }
]
context.objects = [
  { factory = adapter args = { factory.name = support.null-audio-sink
    node.name = fixture-speakers node.description = "Fixture speakers"
    media.class = Audio/Sink audio.position = [ FL FR ] } }
  { factory = adapter args = { factory.name = support.null-audio-sink
    node.name = fixture-headphones node.description = "Fixture headphones"
    media.class = Audio/Sink audio.position = [ FL FR ] } }
  { factory = adapter args = { factory.name = audiotestsrc
    node.name = fixture-microphone node.description = "Fixture microphone"
    media.class = Audio/Source audio.position = [ MONO ] } }
]
"""

class AudioServer:
    @staticmethod
    def configure(root, config_home):
        fragment = config_home / "wireplumber/wireplumber.conf.d"
        fragment.mkdir(parents=True, exist_ok=True)
        (fragment / "90-fixture.conf").write_text(WP_CONFIG)
        (root / "pipewire.conf").write_text(PW_CONFIG)

    def __init__(self, root, env):
        self.root, self.env = root, env
        self.pipewire = self.wireplumber = self.pulse = None
        self.suspended = False
        self.cached = {"volume": 50, "muted": True, "mic_muted": False}
        self.configure(root, Path(env["XDG_CONFIG_HOME"]))
        env["PIPEWIRE_REMOTE"] = "pipewire-0"
        env["PULSE_SERVER"] = "unix:" + str(Path(env["XDG_RUNTIME_DIR"]) / "pulse/native")
        env["PULSE_RUNTIME_PATH"] = str(Path(env["XDG_RUNTIME_DIR"]) / "pulse")
        for key in ("PIPEWIRE_RUNTIME_DIR", "PIPEWIRE_CONFIG_DIR", "WIREPLUMBER_CONFIG_DIR", "WIREPLUMBER_DATA_DIR"):
            env.pop(key, None)

    def launch(self, command, log):
        with (self.root / log).open("w") as output:
            return sp.Popen(command, env=self.env, stdout=output, stderr=sp.STDOUT)

    def command(self, *args):
        return sp.run(["wpctl", *args], env=self.env, capture_output=True, text=True, check=True, timeout=3)

    def start(self):
        self.pipewire = self.launch(["pipewire", "-c", str(self.root / "pipewire.conf")], "audio-pipewire.log")
        deadline = time.monotonic() + 8
        while not (Path(self.env["XDG_RUNTIME_DIR"]) / "pipewire-0").exists():
            assert self.pipewire.poll() is None, (self.root / "audio-pipewire.log").read_text()
            assert time.monotonic() < deadline, "private PipeWire socket"
            time.sleep(.02)
        self.wireplumber = self.launch(["wireplumber"], "audio-wireplumber.log")
        while True:
            try:
                sink = self.command("get-volume", "@DEFAULT_AUDIO_SINK@").stdout
                source = self.command("get-volume", "@DEFAULT_AUDIO_SOURCE@").stdout
                if not sink.startswith("Volume:") or not source.startswith("Volume:"):
                    raise ValueError("default audio nodes are not ready")
                break
            except (sp.CalledProcessError, sp.TimeoutExpired, ValueError):
                assert self.wireplumber.poll() is None, (self.root / "audio-wireplumber.log").read_text()
                assert time.monotonic() < deadline, "private audio defaults"
                time.sleep(.05)

        self.pulse = self.launch(["pipewire-pulse"], "audio-pulse.log")
        while not (Path(self.env["XDG_RUNTIME_DIR"]) / "pulse/native").exists():
            assert self.pulse.poll() is None, (self.root / "audio-pulse.log").read_text()
            assert time.monotonic() < deadline, "private pulse socket"
            time.sleep(.02)

    def state(self):
        if self.pipewire is None or self.suspended:
            return self.cached
        sink = self.command("get-volume", "@DEFAULT_AUDIO_SINK@").stdout
        source = self.command("get-volume", "@DEFAULT_AUDIO_SOURCE@").stdout
        self.cached = {"volume": round(float(sink.split()[1]) * 100, 6), "muted": "MUTED" in sink, "mic_muted": "MUTED" in source}
        return self.cached

    def suspend(self):
        self.cached = self.state()
        self.pipewire.send_signal(signal.SIGSTOP)
        self.suspended = True

    def resume(self):
        if self.suspended:
            self.pipewire.send_signal(signal.SIGCONT)
            self.suspended = False

    def stop(self):
        self.resume()
        for process in (self.pulse, self.wireplumber, self.pipewire):
            if process and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except sp.TimeoutExpired:
                    process.kill()
                    process.wait()
        self.wireplumber = self.pipewire = None
