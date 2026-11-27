{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-audio-check";
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.pipewire
    pkgs.wireplumber
    pkgs.wtype
    pkgs.wlrctl
  ];
  gtkEnv = true;
  headless = true;
  script =
    {
      desktop,
      dbusRun,
      ...
    }:
    ''
      ${dbusRun} python3 - --fixture ${desktop.tests}/bin/desktop-audio-fixture \
        --desktop ${desktop}/bin/desktop-zig --pointer ${desktop.tests}/bin/desktop-pointer-fixture <<'PY'
      import argparse
      import json
      import os
      from pathlib import Path
      import queue
      import signal
      import sys
      import subprocess as sp
      import tempfile
      import threading
      import time
      import wave
      from audio_server import AudioServer
      from session_fixture import wait_until
      from session_fixture import VirtualPointer, read_png
      from wayland_ui import WaylandUI

      parser = argparse.ArgumentParser()
      parser.add_argument("--fixture", required=True)
      parser.add_argument("--desktop", required=True)
      parser.add_argument("--pointer", required=True)
      args = parser.parse_args()
      root = Path(tempfile.mkdtemp(prefix="desktop-audio-check-", dir="/tmp"))
      print(f"Artifacts: {root}", flush=True)
      (root / "runtime").mkdir(mode=0o700)
      AudioServer.configure(root, root / "config")
      env = dict(os.environ, XDG_RUNTIME_DIR=str(root / "runtime"), XDG_CONFIG_HOME=str(root / "config"),
                 XDG_STATE_HOME=str(root / "state"), PIPEWIRE_REMOTE="pipewire-0", PIPEWIRE_DEBUG="1",
                 G_DEBUG="fatal-criticals", GSETTINGS_BACKEND="memory",
                 PULSE_SERVER="unix:" + str(root / "runtime/pulse/native"), PULSE_RUNTIME_PATH=str(root / "runtime/pulse"))
      if "DBUS_SESSION_BUS_ADDRESS" in env:
          env["DBUS_SYSTEM_BUS_ADDRESS"] = env["DBUS_SESSION_BUS_ADDRESS"]
      for key in ("PIPEWIRE_RUNTIME_DIR", "PIPEWIRE_CONFIG_DIR", "WIREPLUMBER_CONFIG_DIR", "WIREPLUMBER_DATA_DIR"):
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
          wait_until(check, description, timeout=timeout)


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
          run(["wpctl", "set-default", headphones])
          expect(lambda s: any(n["id"] == int(headphones) and n["is_default"] for n in s["nodes"]), "external default selection is pushed")
          native("set", speakers, "default")
          expect(lambda s: any(n["id"] == int(speakers) and n["is_default"] for n in s["nodes"]), "native default selection is pushed")
          native("set", microphone, "default")
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
          run(["pw-cli", "set-param", speakers, "Props", "{ channelVolumes: [ 0.125, 0.015625 ] }"])
          expect(lambda s: any(n["id"] == int(speakers) and n["state"] and abs(n["state"]["percent"] - 50) < 0.01 for n in s["nodes"]), "unequal stereo volume is pushed")
          native("set", speakers, "volume", "80")
          def channel_volumes():
              dump = json.loads(run(["pw-dump", speakers]).stdout)
              return dump[0]["info"]["params"]["Props"][0]["channelVolumes"]
          channels = channel_volumes()
          assert abs(channels[0] - 0.512) < 0.0001 and abs(channels[1] - 0.064) < 0.0001, channels
          native("set", speakers, "mute", "1")
          assert channel_volumes() == channels, "mute must preserve channel levels"
          native("set", speakers, "toggle")
          run(["pw-cli", "set-param", speakers, "Props", "{ channelVolumes: [ 0.054872, 0.054872 ] }"])
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
          stream_sound = root / "stream.wav"
          with wave.open(str(stream_sound), "wb") as wav:
              wav.setnchannels(1)
              wav.setsampwidth(2)
              wav.setframerate(48000)
              wav.writeframes(b"\0\0" * 48000 * 60)
          playback = start(["pw-play", "--properties={ application.name = \"Fixture Player\" }", str(stream_sound)], "playback.log")
          recording = start(["pw-record", "--target=fixture-microphone", "--properties={ application.name = \"Fixture Recorder\" }", str(root / "recording.wav")], "recording.log")
          expect(lambda s: any(n["class"] == "playback" for n in s["nodes"]) and any(n["class"] == "recording" for n in s["nodes"]), "application streams appear")
          native("ui")
          ui = WaylandUI(env)
          pointer = VirtualPointer(args.pointer, env=env, delay=0.08)
          try:
              for scale in (1, 2):
                  run([args.desktop, "output", "--output", "HEADLESS-1", "--scale", str(scale)])
                  preview = start([args.fixture, "preview"], f"sound-scale-{scale}.log")
                  wait(lambda: ui.window("Settings"), "native Sound window maps")
                  ui.focus("Settings")
                  time.sleep(.2)
                  filename = root / f"sound-scale-{scale}.png"
                  run([args.desktop, "screenshot", "-o", "HEADLESS-1", str(filename)])
                  width, height, rows = read_png(filename)
                  assert any(row.count(bytes([50, 50, 54])) > 100 for row in rows), "Sound cards did not render"
                  logical_width = width / scale
                  sidebar = min(280, logical_width * .3)
                  content_width = min(576, logical_width - sidebar - 48)
                  content_x = sidebar + (logical_width - sidebar - content_width) / 2
                  pointer.command(f"size {width} {height}")
                  for nav_y in (73, 118, 163):
                      pointer.move(90 * scale, nav_y * scale)
                      pointer.command("button 1")
                      pointer.command("button 0")
                      time.sleep(.15)
                      assert ui.window("Settings"), "page switch closed the settings shell"
                  run(["wtype", "-k", "Tab"])
                  pointer.move((content_x + 182) * scale, 197 * scale)
                  pointer.command("button 1")
                  pointer.move((content_x + content_width - 24) * scale, 197 * scale)
                  pointer.command("button 0")
                  wait(lambda: "1.00" in run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]).stdout,
                      "native pointer slider drag at scale " + str(scale))
                  run(["wtype", "-k", "Home", "-k", "Right"])
                  wait(lambda: "0.05" in run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]).stdout,
                      "native keyboard slider adjustment")
                  pointer.move((content_x + 146) * scale, 197 * scale)
                  time.sleep(.7)
                  run([args.desktop, "screenshot", "-o", "HEADLESS-1", str(filename)])
                  assert any(row.count(bytes([22, 22, 25])) > 30 for row in read_png(filename)[2]), "Native tooltip missing"
                  if scale == 1:
                      run(["wtype", "-k", "Escape"])
                  else:
                      ui.run("wlrctl", "toplevel", "close", "title:Settings")
                  assert preview.wait(timeout=10) == 0, (root / f"sound-scale-{scale}.log").read_text()
              print("PASS native Sound Wayland pixels, pointer drag, keyboard, tooltips, HiDPI and close requests", flush=True)
          finally:
              pointer.close()
              ui.keyboard.socket.close()
              run([args.desktop, "output", "--output", "HEADLESS-1", "--scale", "1"], check=False)
          for process in (playback, recording):
              process.terminate()
              process.wait(timeout=5)
          print("PASS native quick-settings and sound-settings widgets", flush=True)
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
      PY
    '';
}
