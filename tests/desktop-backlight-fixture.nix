{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-backlight-check";
  pygobject = true;
  withDesktop = true;
  gtkEnv = true;
  memorySettings = true;
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.glib
    pkgs.xorg-server
    pkgs.grim
    pkgs.wlr-randr
    pkgs.wtype
    pkgs.pipewire
    pkgs.wireplumber
  ];
  script =
    {
      desktop,
      dbusConfig,
      dbusRun,
      ...
    }:
    ''
      Xvfb :98 -nolisten tcp &
      xvfb_pid=$!
      trap 'kill "$xvfb_pid"' EXIT
      for attempt in $(seq 1 100); do
        test -S /tmp/.X11-unix/X98 && break
        sleep 0.05
      done
      DISPLAY=:98 GDK_BACKEND=x11 python3 - \
        --fixture ${desktop.tests}/bin/desktop-backlight-fixture \
        --dbus-config ${dbusConfig} <<'PY'
      import argparse
      import json
      import os
      from pathlib import Path
      import shutil
      import subprocess as sp
      import tempfile
      from backlight_mock import BacklightMock

      parser = argparse.ArgumentParser()
      parser.add_argument("--fixture", required=True)
      parser.add_argument("--dbus-config")
      args = parser.parse_args()
      root = Path(tempfile.mkdtemp(prefix="desktop-backlight-check-", dir="/tmp"))
      print(f"Artifacts: {root}", flush=True)
      mock = BacklightMock(root, args.dbus_config)
      env = dict(os.environ, DESKTOP_BACKLIGHT_FIXTURE_ROOT=str(mock.sysfs),
                 DBUS_SYSTEM_BUS_ADDRESS=mock.address, G_DEBUG="fatal-criticals", GSETTINGS_BACKEND="memory")
      (root / "tools").mkdir()
      for tool in ("nmcli", "upower", "wpctl"):
          file = root / "tools" / tool
          file.write_text(f"#!{shutil.which('sh')}\nexit 0\n")
          file.chmod(0o755)
      env["PATH"] = str(root / "tools") + os.pathsep + env["PATH"]


      def run(*command, success=True):
          result = sp.run([args.fixture, *command], env=env, capture_output=True, text=True, timeout=10)
          assert (result.returncode == 0) == success, result.stderr
          return json.loads(result.stdout) if success and result.stdout else None


      try:
          assert run("read")["percent"] == 20
          assert run("step", "-100")["current"] == 20
          assert run("step", "100")["current"] == 400
          assert run("set", "0")["current"] == 4
          assert run("set", "33.5")["current"] == 134
          before = len(mock.calls)
          run("set", "nan", success=False)
          assert len(mock.calls) == before
          mock.deny = True
          run("set", "70", success=False)
          assert run("read")["current"] == 134, "Permission denial changed sysfs"
          mock.deny = False
          mock.device("z-platform", 20, 100, "platform")
          mock.device("firmware", 10, 100, "firmware")
          mock.device("a-firmware", 30, 200, "firmware")
          assert run("read")["device"] == "a-firmware", "Device selection is not deterministic"
          (mock.sysfs / "a-firmware/max_brightness").write_text("0\n")
          assert run("read")["device"] == "firmware"
          for name in ("firmware", "a-firmware", "z-platform"):
              shutil.rmtree(mock.sysfs / name)
          (mock.sysfs / "intel/max_brightness").write_text("invalid\n")
          run("read", success=False)
          mock.device("intel", 500, 400, "raw")
          run("read", success=False)
          mock.device("intel", 80, 400, "raw")
          mock.delay = 250
          run("controls")
          assert mock.calls[-3:] == [("backlight", "intel", 300), ("backlight", "intel", 152), ("backlight", "intel", 4)], mock.calls
          mock.device("intel", 80, 400, "raw")
          mock.deny = True
          run("controls-denied")
          assert int((mock.sysfs / "intel/brightness").read_text()) == 80
          mock.deny = False
          shutil.rmtree(mock.sysfs / "intel")
          before = len(mock.calls)
          run("read", success=False)
          run("set", "50", success=False)
          run("controls-empty")
          assert len(mock.calls) == before, "Missing device caused a write"
          print("PASS: device discovery, ordering, malformed/absent devices, rounding, key/slider floors, logind denial, queued slider writes and cancellation")
      finally:
          mock.stop()
      PY
      ${dbusRun} python3 - \
        --binary ${desktop.tests}/bin/desktop-backlight-fixture \
        --dbus-config ${dbusConfig} <<'PY'
      import argparse
      import json
      import os
      import re
      import shutil
      import subprocess as sp
      import tempfile
      import time
      from backlight_mock import BacklightMock
      from audio_server import AudioServer
      from pathlib import Path
      from session_fixture import terminate_processes, wait_until, wait_wayland

      parser = argparse.ArgumentParser()
      parser.add_argument("--binary", required=True, type=Path)
      parser.add_argument("--style", type=Path)
      parser.add_argument("--dbus-config", type=Path)
      args = parser.parse_args()
      for tool in ("desktop-zig", "grim", "wlr-randr", "wtype", "dbus-send"):
          if shutil.which(tool) is None:
              parser.error(f"Missing executable: {tool}")
      root = Path(tempfile.mkdtemp(prefix="desktop-osd-check-"))
      print(f"Artifacts: {root}", flush=True)
      (root / "runtime").mkdir(mode=0o700)
      (root / "config").mkdir(parents=True)
      state_file = root / "state.json"
      state_file.write_text(json.dumps({"brightness": 20}))
      def set_brightness(percent):
          state = json.loads(state_file.read_text())
          state["brightness"] = percent
          updated = state_file.with_suffix(".tmp")
          updated.write_text(json.dumps(state))
          updated.replace(state_file)

      backlight = BacklightMock(root, args.dbus_config, on_set=set_brightness)
      env = dict(os.environ)
      for name in ("DISPLAY", "WAYLAND_DISPLAY"):
          env.pop(name, None)
      env.update(
          OSD_TEST_ROOT=str(root),
          DESKTOP_BACKLIGHT_FIXTURE_ROOT=str(backlight.sysfs),
          DBUS_SYSTEM_BUS_ADDRESS=backlight.address,
          XDG_RUNTIME_DIR=str(root / "runtime"),
          XDG_CONFIG_HOME=str(root / "config"),
          XDG_DATA_DIRS=env.get("XDG_DATA_DIRS", "/run/current-system/sw/share"),
          XDG_CACHE_HOME=str(root / "cache"),
          WLR_BACKENDS="headless",
          WLR_HEADLESS_OUTPUTS="2",
          NO_AT_BRIDGE="1",
          GIO_USE_VFS="local",
          GTK_USE_PORTAL="0",
      )
      processes = []
      audio = AudioServer(root, env)


      def start(command, filename, extra=None):
          with (root / filename).open("w") as output:
              process = sp.Popen(
                  command, env=env | (extra or {}), stdout=output, stderr=sp.STDOUT
              )
          processes.append(process)
          return process


      def run(command, check=True):
          return sp.run(
              command, env=env, check=check, capture_output=True, text=True, timeout=8
          )


      def send(*command):
          run([str(args.binary), *command])


      def wait_for(predicate, seconds=6):
          wait_until(predicate, lambda: "Timed out waiting for state; " + log()[-3000:], timeout=seconds)


      def state():
          return json.loads(state_file.read_text()) | audio.state()


      def pixels(name, output="HEADLESS-1"):
          # PPM keeps screen capture comparisons within the overlay's short lifetime.
          path = root / (name + ".ppm")
          run(["${pkgs.grim}/bin/grim", "-t", "ppm", "-o", output, str(path)])
          return path.read_bytes()


      def log():
          return (root / "osd.log").read_text()


      try:
          audio.start()
          audio.command("set-volume", "@DEFAULT_AUDIO_SINK@", "0.5")
          audio.command("set-mute", "@DEFAULT_AUDIO_SINK@", "1")
          audio.command("set-mute", "@DEFAULT_AUDIO_SOURCE@", "0")
          compositor = start(["desktop-zig", "compositor-only"], "compositor.log")
          env["WAYLAND_DISPLAY"] = wait_wayland(root / "runtime", compositor, root / "compositor.log")
          run(["wlr-randr", "--output", "HEADLESS-1", "--custom-mode", "1728x1080", "--pos", "0,0",
               "--output", "HEADLESS-2", "--custom-mode", "1280x800", "--pos", "1728,0"])
          assert run([str(args.binary), "volume", "up"], check=False).returncode != 0
          assert not (root / "calls.log").exists()
          start(["wtype", "-s", "55000"], "keyboard.log")
          start([str(args.binary.parent / "desktop-switcher-fixture"), "org.dotfiles.OsdFocusFixture", "OSD focus fixture"], "focus.log")
          wait_for(lambda: "OSD focus fixture" in (root / "focus.log").read_text())
          time.sleep(0.2)
          server = start([str(args.binary), "serve"], "osd.log", {"G_DEBUG": "fatal-criticals", "WAYLAND_DEBUG": "1"})

          def registered():
              result = run(["dbus-send", "--session", "--print-reply", "--dest=org.freedesktop.DBus",
                            "/org/freedesktop/DBus", "org.freedesktop.DBus.NameHasOwner", "string:org.dotfiles.DesktopOsd"])
              return "boolean true" in result.stdout

          wait_for(registered)
          time.sleep(0.4)
          baseline = pixels("hidden")
          baseline_second = pixels("hidden-second", "HEADLESS-2")
          send("volume", "up")
          wait_for(lambda: pixels("volume") != baseline)
          wait_for(lambda: pixels("volume-second", "HEADLESS-2") != baseline_second)
          wait_for(lambda: state()["volume"] == 55 and not state()["muted"])
          assert log().count('"desktop-osd")') == 2
          assert "set_exclusive_zone(-1)" in log()
          assert "set_keyboard_interactivity(0)" in log()
          assert not re.search(r"wl_keyboard#\d+\.enter\(", log()), "OSD stole keyboard focus"
          print("PASS unmute, volume step, two passive overlays and icon rendering", flush=True)
          clients = [sp.Popen([str(args.binary), "volume", "up"], env=env, stdout=sp.DEVNULL, stderr=sp.DEVNULL) for _ in range(25)]
          for client in clients:
              assert client.wait(timeout=8) == 0
          wait_for(lambda: state()["volume"] == 100)
          time.sleep(0.3)
          clients = [sp.Popen([str(args.binary), "volume", "down"], env=env, stdout=sp.DEVNULL, stderr=sp.DEVNULL) for _ in range(12)]
          for client in clients:
              assert client.wait(timeout=8) == 0
          wait_for(lambda: state()["volume"] == 40)
          send("volume", "mute")
          wait_for(lambda: state()["muted"])
          time.sleep(0.15)
          pixels("muted")
          send("microphone", "mute")
          wait_for(lambda: state()["mic_muted"])
          time.sleep(0.15)
          pixels("microphone")
          print("PASS key repeat, 100 percent cap and native mute toggles", flush=True)
          for _ in range(8):
              send("brightness", "down")
          wait_for(lambda: state()["brightness"] == 5)
          time.sleep(0.2)
          pixels("brightness-floor")
          for _ in range(22):
              send("brightness", "up")
          wait_for(lambda: state()["brightness"] == 100)
          time.sleep(0.2)
          pixels("brightness-ceiling")
          time.sleep(1.6)
          assert pixels("dismissed") == baseline, "OSD did not disappear"
          print("PASS brightness limits and automatic dismissal", flush=True)
          audio.suspend()
          send("volume", "down")
          send("brightness", "down")
          wait_for(lambda: state()["brightness"] == 95)
          audio.resume()
          time.sleep(.2)
          audio.stop()
          time.sleep(.2)
          send("volume", "down")
          send("brightness", "down")
          wait_for(lambda: state()["brightness"] == 90)
          print("PASS native audio timeout, disconnect and queue recovery", flush=True)
          run(["wlr-randr", "--output", "HEADLESS-1", "--custom-mode", "2808x1755", "--scale", "1.625"])
          run(["wlr-randr", "--output", "HEADLESS-2", "--off"])
          time.sleep(0.2)
          run(["wlr-randr", "--output", "HEADLESS-2", "--on"])
          time.sleep(0.2)
          send("brightness", "up")
          wait_for(lambda: state()["brightness"] == 95)
          time.sleep(0.2)
          pixels("fractional-scale")
          pixels("reenabled-output", "HEADLESS-2")
          assert server.poll() is None
          assert not re.search(r"CRITICAL|panic:|assertion", log()), log()[-3000:]
          focus_events = re.findall(r"^\d+ OSD focus fixture$", (root / "focus.log").read_text(), re.MULTILINE)
          assert len(focus_events) == 1, ("Application focus changed", focus_events)
          assert not re.search(r"wl_keyboard#\d+\.enter\(", log()), "OSD stole keyboard focus"
          print("PASS fractional scale and output disable/reenable", flush=True)
          server.terminate()
          assert server.wait(timeout=5) == 0
          print("PASS clean shutdown", flush=True)
      finally:
          audio.stop()
          backlight.stop()
          terminate_processes(processes, timeout=3)
      PY
    '';
}
