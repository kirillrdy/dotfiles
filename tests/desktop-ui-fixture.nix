{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-ui-check";
  fixture = {
    name = "desktop-integration-tests";
    steps = "test-binary -Dintegration-tests=true";
  };
  pygobject = true;
  gtkEnv = true;
  memorySettings = true;
  cacheDir = true;
  headless = true;
  fontDirs = [
    pkgs.adwaita-fonts
    pkgs.dejavu_fonts
  ];
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.wtype
    pkgs.wlrctl
    pkgs.wlr-randr
  ];
  script =
    {
      desktop,
      fixture,
      dbusRun,
      ...
    }:
    ''
      export DESKTOP_PANEL_ICON_PATH=${pkgs.adwaita-icon-theme}/share/icons
      export DESKTOP_APPS_ICON_PATH=${pkgs.adwaita-icon-theme}/share/icons
      export G_DEBUG=fatal-criticals

      # Fixtures exit successfully even when their checking allocator reports
      # leaks; fail on those reports.
      no_leaks() {
        local status=0
        "$@" 2>fixture.stderr || status=$?
        cat fixture.stderr >&2
        if grep -q "SafeAllocator): leaked" fixture.stderr; then
          echo "$1 leaked allocations" >&2
          return 1
        fi
        return "$status"
      }

      # Screen pixel checks run before other fixtures map their windows.
      no_leaks ${fixture}/bin/desktop-tests
      for name in apps dash widgets settings polkit screenshot; do
        no_leaks ${desktop.tests}/bin/desktop-$name-fixture
      done
      no_leaks ${desktop.tests}/bin/desktop-askpass-fixture ${desktop}/bin/desktop-zig
      mkdir clients
      ln -s ${desktop.tests}/bin/* clients/
      ln -s ${desktop}/bin/desktop-zig clients/desktop-zig
      python3 - --binary clients/desktop-window-fixture <<'PY'
      import argparse
      import os
      from pathlib import Path
      import subprocess
      import time
      from wayland_ui import WaylandUI

      parser = argparse.ArgumentParser()
      parser.add_argument("--binary", required=True)
      args = parser.parse_args()
      forms = subprocess.run([args.binary, "forms"], capture_output=True, text=True, timeout=10)
      assert forms.returncode == 0, forms.stdout + forms.stderr
      assert "PASS GTK-free production forms" in forms.stderr, forms.stderr
      print(forms.stderr.strip(), flush=True)
      ui = WaylandUI(dict(os.environ))
      title = "Native Wayland fixture"
      for close_with_escape in (True, False):
          process = subprocess.Popen([args.binary], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
          try:
              deadline = time.monotonic() + 10
              while not ui.window(title):
                  assert process.poll() is None, process.communicate()
                  assert time.monotonic() < deadline, "native window did not map"
                  time.sleep(0.02)
              loaded = Path(f"/proc/{process.pid}/maps").read_text()
              assert "libgtk-" not in loaded and "libgdk-3" not in loaded, "native window loaded GTK/GDK"
              ui.focus(title)
              ui.type("Cafe 日本語")
              if close_with_escape:
                  ui.key("Escape")
              else:
                  ui.run("wlrctl", "toplevel", "close", "title:" + title)
              out, err = process.communicate(timeout=10)
              assert process.returncode == 0, out + err
              assert "PASS GTK-free native window" in err, out + err
              print(err.strip(), flush=True)
          finally:
              if process.poll() is None:
                  process.terminate()
                  process.communicate(timeout=5)

      for accepted in (False, True):
          process = subprocess.Popen([args.binary, "consent"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
          try:
              deadline = time.monotonic() + 10
              while not ui.window("Native consent fixture"):
                  assert process.poll() is None, process.communicate()
                  assert time.monotonic() < deadline, "native consent did not map"
                  time.sleep(0.02)
              loaded = Path(f"/proc/{process.pid}/maps").read_text()
              assert "libgtk-" not in loaded and "libgdk-3" not in loaded, "native consent loaded GTK/GDK"
              ui.focus("Native consent fixture")
              ui.key("alt+s" if accepted else "Return")
              out, err = process.communicate(timeout=10)
              assert process.returncode == 0, out + err
              assert f"PASS GTK-free consent accepted={str(accepted).lower()}" in err, out + err
              print(err.strip(), flush=True)
          finally:
              if process.poll() is None:
                  process.terminate()
                  process.communicate(timeout=5)
      PY
      python3 - --bin-dir clients --wtype ${pkgs.wtype}/bin/wtype <<'PY'
      import argparse
      import os
      import pathlib
      import select
      import subprocess
      import tempfile
      import time

      parser = argparse.ArgumentParser()
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
          run([bin + "desktop-window-fixture", "idle"])
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
              windows[title] = start(title, [bin + "desktop-switcher-fixture", "io.test." + app, title])
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
          keys("-M", "logo", "-k", "grave", "-m", "logo")
          wait(lambda: focused() == "Browser 1", "Super-grave")
          keys("-M", "logo", "-M", "shift", "-k", "grave", "-m", "shift", "-m", "logo")
          wait(lambda: focused() == "Browser 2", "Super-Shift-grave")
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
          print(run([bin + "desktop-decoration-fixture"]), flush=True)
          switcher_checks()
          first = start(
              "first", [bin + "desktop-switcher-fixture", "com.dotfiles.First", "First"]
          )
          second = start(
              "second", [bin + "desktop-switcher-fixture", "com.dotfiles.Second", "Second"]
          )
          wait(lambda: "First" in probe("list") and "Second" in probe("list"), "windows")
          print(probe("capture"), flush=True)
          assert "workspace 0/4" in probe("list")
          run([bin + "desktop-zig", "output", "--output", "HEADLESS-1", "--scale", "1.25"])
          print("output scale applied", flush=True)
          probe("move", "First", "1")
          assert "window First workspace 1" in probe("list")
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
      PY
      python3 - --binary ${desktop}/bin/desktop-zig --wtype ${pkgs.wtype}/bin/wtype <<'PY'
      import argparse
      import os
      from pathlib import Path
      import subprocess as sp
      import tempfile
      import time

      parser = argparse.ArgumentParser()
      parser.add_argument("--binary", required=True)
      parser.add_argument("--wtype", default="wtype")
      args = parser.parse_args()
      root = Path(tempfile.mkdtemp(prefix="desktop-askpass-input-", dir="/tmp"))
      print(f"Askpass input artifacts: {root}", flush=True)
      (root / "runtime").mkdir(mode=0o700)
      env = dict(os.environ, XDG_RUNTIME_DIR=str(root / "runtime"),
                 XDG_CONFIG_HOME=str(root / "config"), XDG_CACHE_HOME=str(root / "cache"),
                 DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-system-bus"),
                 WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1",
                 GDK_BACKEND="wayland", GSETTINGS_BACKEND="memory")
      for name in ("DISPLAY", "WAYLAND_DISPLAY"):
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
      PY
      ${dbusRun} python3 - clients/desktop-command-fixture <<'PY'
      import subprocess
      import sys
      import time
      from gi.repository import Gio, GLib

      bus = Gio.bus_get_sync(Gio.BusType.SESSION)
      bus.call_sync(
          "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
          "RequestName", GLib.Variant("(su)", ("org.freedesktop.Notifications", 0)),
          None, Gio.DBusCallFlags.NONE, -1, None,
      )
      interface = Gio.DBusNodeInfo.new_for_xml("""
      <node><interface name="org.freedesktop.Notifications"><method name="Notify">
      <arg type="s" direction="in"/><arg type="u" direction="in"/>
      <arg type="s" direction="in"/><arg type="s" direction="in"/>
      <arg type="s" direction="in"/><arg type="as" direction="in"/>
      <arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
      <arg type="u" direction="out"/>
      </method></interface></node>
      """).interfaces[0]
      messages = []


      def notify(connection, sender, path, iface, method, params, invocation):
          values = params.unpack()
          assert values[3] == "Desktop command failed", values
          messages.append(values[4])
          invocation.return_value(GLib.Variant("(u)", (len(messages),)))


      registration = bus.register_object("/org/freedesktop/Notifications", interface, notify)
      process = subprocess.Popen([sys.argv[1]], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
      deadline = time.monotonic() + 10
      try:
          while process.poll() is None:
              while GLib.MainContext.default().iteration(False):
                  pass
              assert time.monotonic() < deadline, "Command watcher hung"
              time.sleep(0.01)
          stdout, stderr = process.communicate(timeout=1)
          assert process.returncode == 0, stderr
          assert len(messages) == 4, (messages, stderr)
          for label in ("Nonzero command", "Signaled command", "Missing command", "Invalid command"):
              assert sum(message.startswith(label + ":") for message in messages) == 1, messages
              assert label in stderr, stderr
          assert any("7" in message and message.startswith("Nonzero command:") for message in messages), messages
          assert "Successful command" not in stderr, stderr
          print("PASS: nonzero exits, signals, spawn/parse errors notify and log; success is quiet")
      finally:
          if process.poll() is None:
              process.kill()
              process.wait()
          bus.unregister_object(registration)
      PY
      ${dbusRun} python3 - clients <<'PY'
      import os
      from pathlib import Path
      import re
      import subprocess as sp
      import sys
      import tempfile
      import time
      from gi.repository import GLib
      from session_fixture import NotificationsClient, VirtualPointer, read_png, terminate_processes, wait_until

      bin_dir = Path(sys.argv[1]).resolve()
      root = Path(tempfile.mkdtemp(prefix="desktop-notifications-check-", dir="/tmp"))
      print(f"Notification artifacts: {root}", flush=True)
      client = NotificationsClient()
      name, control, signals = client.name, client.control, client.signals
      history, clear = client.history, client.clear


      def call(member, parameters=None, iface=name):
          return client.call(member, parameters, iface=iface)


      def wait_for(predicate, description, seconds=8):
          def check_service():
              assert service.poll() is None, log.read_text()[-8000:]
          wait_until(predicate, description, timeout=seconds, interval=0.02, step=client.pump, on_error=check_service)


      def notify(body="Notification body", actions=(), critical=True, resident=False, transient=False, replace=0, image=False):
          hints = {"urgency": GLib.Variant("y", 2 if critical else 1),
                   "resident": GLib.Variant("b", resident), "transient": GLib.Variant("b", transient)}
          if image:
              hints["image-data"] = GLib.Variant("(iiibiiay)", (2, 1, 8, True, 8, 4, bytes([255, 0, 0, 255, 0, 0, 255, 255])))
          return call("Notify", GLib.Variant("(susssasa{sv}i)", (
              "Messages", replace, "application-x-executable-symbolic", "東京 — مرحبا", body, list(actions), hints, -1)))[0]


      def pointer_command(command):
          pointer.command(command)


      def move(x, y):
          pointer.move(x, y)


      def click(x, y):
          pointer.click(x, y)


      def capture(label):
          filename = root / (label + ".png")
          sp.run([str(bin_dir / "desktop-zig"), "screenshot", "-o", "HEADLESS-1", str(filename)], check=True, timeout=10)
          return read_png(filename)


      def card_bottom(rows):
          return max((y for y, row in enumerate(rows) if row.count(bytes([84, 84, 90])) > 100), default=-1)


      log = root / "service.log"
      with log.open("w") as output:
          service = sp.Popen([str(bin_dir / "desktop-notifications-fixture")],
                             stdout=output, stderr=sp.STDOUT, env=dict(os.environ, WAYLAND_DEBUG="client", G_DEBUG="fatal-criticals"))
      pointer = VirtualPointer(bin_dir / "desktop-pointer-fixture", delay=0.07)
      scaled = False
      try:
          wait_for(client.owned, "Notification name ownership")
          width, height, baseline = capture("baseline")
          pointer_command(f"size {width} {height}")
          move(0, height - 1)
          left = (width - 529) // 2

          identifier = notify("<b>Bold message</b> &amp; 東京 " * 20, ("default", "Open", "reply", "Reply", "archive", "Archive"), image=True)
          wait_for(lambda: '"desktop-notifications"' in log.read_text(), "Native notification surface")
          time.sleep(0.2)
          _, _, collapsed = capture("collapsed")
          collapsed_bottom = card_bottom(collapsed)
          assert 90 < collapsed_bottom < 130, collapsed_bottom
          assert collapsed[height // 2] == baseline[height // 2], "Banner must leave the desktop below it unchanged"
          assert any(row[x] > 200 and row[x + 1] < 30 and row[x + 2] < 60
                     for row in collapsed[50:105] for x in range(0, len(row), 3)), "Raw image hint missing"
          click(left + 458, 28)
          _, _, expanded = capture("expanded")
          expanded_bottom = card_bottom(expanded)
          assert expanded_bottom > collapsed_bottom + 60, (collapsed_bottom, expanded_bottom)
          click(left + 70, expanded_bottom - 27)
          wait_for(lambda: ("ActionInvoked", (identifier, "reply")) in signals, "Action button signal")
          wait_for(lambda: ("NotificationClosed", (identifier, 2)) in signals, "Action closes notification")
          assert not history()

          identifier = notify(actions=("default", "Open"), resident=True)
          time.sleep(0.15)
          click(left + 180, 65)
          wait_for(lambda: ("ActionInvoked", (identifier, "default")) in signals, "Default action")
          assert history()[0]["id"] == identifier
          move(left + 490, 28)
          pointer_command("button 1")
          move(left + 180, 65)
          pointer_command("button 0")
          assert history()[0]["id"] == identifier, "Drag out must cancel dismissal"
          assert notify("Replacement <invalid markup", replace=identifier, resident=True) == identifier
          assert history()[0]["body"] == "Replacement <invalid markup"
          time.sleep(0.15)
          capture("replacement-invalid-markup")
          click(left + 490, 28)
          wait_for(lambda: not history(), "Close button")

          identifier = notify(critical=False, transient=True)
          time.sleep(0.15)
          move(left + 180, 65)
          time.sleep(4.2)
          assert history()[0]["id"] == identifier
          assert card_bottom(capture("hovered")[2]) > 90
          move(0, height - 1)
          wait_for(lambda: ("NotificationClosed", (identifier, 1)) in signals, "Transient expiry after pointer leave")
          assert not history()
          identifier = notify(critical=False)
          time.sleep(4.3)
          assert history()[0]["id"] == identifier, "Non-transient expiry retains history"
          assert card_bottom(capture("expired-history")[2]) == -1
          clear()

          notify("Ordinary queued message", critical=False)
          identifier = notify("Critical message", resident=True, actions=("default", "Open"))
          time.sleep(4.2)
          assert card_bottom(capture("critical")[2]) > 90
          click(left + 180, 65)
          wait_for(lambda: ("ActionInvoked", (identifier, "default")) in signals, "Critical preemption")
          call("CalendarOpen", GLib.Variant("(b)", (True,)), iface=control)
          time.sleep(0.1)
          assert card_bottom(capture("calendar-open")[2]) == -1
          assert len(history()) == 2
          clear()
          call("CalendarOpen", GLib.Variant("(b)", (False,)), iface=control)

          identifier = notify(actions=("default", "Open"), resident=True)
          time.sleep(0.15)
          sp.run([str(bin_dir / "desktop-zig"), "output", "--output", "HEADLESS-1", "--scale", "2"], check=True, timeout=10)
          scaled = True
          time.sleep(0.3)
          _, _, scaled_rows = capture("scale-2")
          assert card_bottom(scaled_rows) > 180
          pointer_command(f"size {width // 2} {height // 2}")
          click((width // 2 - 529) // 2 + 490, 28)
          wait_for(lambda: not history(), "Scaled close button")
          sp.run([str(bin_dir / "desktop-zig"), "output", "--output", "HEADLESS-1", "--scale", "1"], check=True, timeout=10)
          scaled = False
          service.terminate()
          assert service.wait(timeout=8) == 0
          assert not re.search(r"CRITICAL|assertion|panic:|Segmentation|notification .*failed", log.read_text()), log.read_text()[-8000:]
          print("PASS: native banner pixels, Unicode/markup/images, expansion, actions, replacement, resident/critical/history, hover expiry, calendar suppression and live scaling")
      finally:
          client.close()
          if scaled:
              sp.run([str(bin_dir / "desktop-zig"), "output", "--output", "HEADLESS-1", "--scale", "1"], timeout=10)
          pointer.close()
          terminate_processes([service], timeout=8)
      PY
      ${dbusRun} python3 - clients <<'PY'
      import json
      import os
      from pathlib import Path
      import subprocess as sp
      import sys
      import tempfile
      import time
      from gi.repository import GLib
      from session_fixture import NotificationsClient, VirtualPointer, read_png, terminate_processes, wait_until, write_wallpaper

      bin_dir = Path(sys.argv[1]).resolve()
      root = Path(tempfile.mkdtemp(prefix="desktop-date-menu-check-", dir="/tmp"))
      print(f"Date menu artifacts: {root}", flush=True)
      client = NotificationsClient()
      bus, name, control, signals = client.bus, client.name, client.control, client.signals
      call, history = client.call, client.history


      def wait_for(predicate, description):
          def check_service():
              assert service.poll() is None, log.read_text()[-8000:]
          return wait_until(predicate, description, timeout=10, interval=0.05, step=client.pump, on_error=check_service)


      def notify(body="Body", actions=(), resident=False, replace=0):
          hints = {"urgency": GLib.Variant("y", 1), "resident": GLib.Variant("b", resident)}
          return call("Notify", GLib.Variant("(susssasa{sv}i)", (
              "Messages 東京", replace, "application-x-executable-symbolic", "مرحبا <&>", body, list(actions), hints, 0)), name)[0]


      def pointer_command(command):
          pointer.command(command)


      def move(x, y):
          pointer.move(x, y)


      def click(x, y):
          pointer.click(left + x, top + y)


      def capture(label):
          filename = root / (label + ".png")
          sp.run([str(bin_dir / "desktop-zig"), "screenshot", "-o", "HEADLESS-1", str(filename)], check=True, timeout=10)
          return read_png(filename)


      def popup_origin(rows):
          separator = bytes([74, 74, 78])
          runs = {}
          for y, row in enumerate(rows):
              active = {}
              x = row.find(separator)
              while x >= 0:
                  if x % 3 == 0:
                      start, end = runs.get(x, (y, y - 1))
                      if end != y - 1:
                          start = y
                      active[x] = start, y
                      if y - start >= 399:
                          return x // 3 - 444, start - 8
                  x = row.find(separator, x + 3)
              runs = active
          return None


      def pane(rows, x, width, y=0, height=420):
          return b"".join(row[(left + x) * 3:(left + x + width) * 3] for row in rows[top + y:top + y + height])


      def wait_for_scroll(before, label, description):
          previous = pane(before, 8, 424, 8, 352)
          def changed():
              rows = capture(label)[2]
              if pane(rows, 8, 424, 8, 352) != previous:
                  return rows
          return wait_for(changed, description)


      def card_ready():
          rows = capture("live")[2]
          return rows[top + 108][(left + 100) * 3:(left + 100) * 3 + 3] == bytes([84, 84, 90])


      write_wallpaper(root / "wallpaper.png")
      (root / "panel.json").write_text(json.dumps({
          "left": [], "center": [{"kind": "clock"}], "right": [],
      }))
      env = dict(os.environ, G_DEBUG="fatal-criticals", WB_PANEL_DEMO="1",
                 GSETTINGS_BACKEND="memory", XDG_CONFIG_HOME=str(root / "config"),
                 XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"),
                 DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-system-bus"))
      log = root / "service.log"
      keyboard = sp.Popen(["wtype", "-s", "120000"])
      time.sleep(.1)
      with log.open("w") as output:
          service = sp.Popen([str(bin_dir / "desktop-zig"), "serve", str(root / "wallpaper.png"),
                              str(root / "panel.json")], stdout=output, stderr=sp.STDOUT, env=env)
      pointer = VirtualPointer(bin_dir / "desktop-pointer-fixture", delay=0.07)
      try:
          wait_for(client.owned, "Notification owner")
          width, height, _ = capture("panel")
          pointer_command(f"size {width} {height}")
          pointer.click(width // 2, 8)
          left, top = wait_for(lambda: popup_origin(capture("opening")[2]), "Native popup mapping")
          move(0, height - 1)
          before = capture("calendar-before")[2]
          click(480, 113)
          move(0, height - 1)
          previous = capture("calendar-previous")[2]
          assert pane(before, 460, 280) != pane(previous, 460, 280), "Previous month did not redraw"
          click(600, 40)
          click(480, 191)
          move(0, height - 1)
          selected = capture("calendar-selected")[2]
          sp.run(["wtype", "-k", "Right"], check=True, timeout=5)
          wait_for(lambda: pane(selected, 460, 280) != pane(capture("calendar-keyboard")[2], 460, 280), "Keyboard date selection did not redraw")

          identifier = notify("<b>Long body</b> &amp; 東京 " * 20,
              ("default", "Open", "reply", "Reply", "archive", "Archive"), resident=True)
          wait_for(card_ready, "History notification rendering")
          click(366, 40)
          move(0, height - 1)
          card_color = bytes([84, 84, 90])
          def card_bottom():
              rows = capture("expanded")[2]
              return max(y - top for y, row in enumerate(rows[top:top + 360], top)
                  if row[(left + 20) * 3:(left + 420) * 3].count(card_color) > 100)
          wait_for(lambda: card_bottom() > 200, "Expanded history card frame")
          bottom = card_bottom()
          click(60, bottom - 26)
          wait_for(lambda: ("ActionInvoked", (identifier, "reply")) in signals, "Named history action")
          assert len(history()) == 1, "Resident action must retain the notification"
          notify("Replacement <invalid markup", ("default", "Open", "reply", "Reply"), resident=True, replace=identifier)
          time.sleep(.2)
          replaced = capture("replacement")[2]
          assert any(row[(left + 40) * 3:(left + 400) * 3].count(card_color) > 100
              for row in replaced[top + 140:top + 155]), "Replacement lost expansion"
          click(180, 90)
          wait_for(lambda: ("ActionInvoked", (identifier, "default")) in signals, "Default history action")
          move(left + 400, top + 40)
          pointer_command("button 1")
          move(left + 440, top + 40)
          pointer_command("button 0")
          assert len(history()) == 1, "Dragging away from Close must cancel dismissal"
          click(400, 40)
          wait_for(lambda: not history(), "History dismissal")

          for i in range(8):
              notify(f"History item {i}")
          wait_for(card_ready, "History burst rendering")
          time.sleep(.2)
          click(160, 90)
          wait_for(lambda: len(history()) == 7, "Non-resident history activation")
          time.sleep(.2)
          move(0, height - 1)
          unscrolled = capture("history-top")[2]
          move(left + 436, top + 30)
          pointer_command("button 1")
          move(left + 436, top + 352)
          pointer_command("button 0")
          dragged = wait_for_scroll(unscrolled, "history-dragged", "History scrollbar drag")
          sp.run(["wtype", "-k", "Page_Up"], check=True, timeout=5)
          wait_for_scroll(dragged, "history-paged-up", "History keyboard paging")
          sp.run(["wtype", "-k", "Page_Down"], check=True, timeout=5)
          scrolled = wait_for_scroll(unscrolled, "history-scrolled", "History did not scroll")
          assert pane(unscrolled, 460, 280) == pane(scrolled, 460, 280), "History scrolling changed calendar pixels"
          click(55, 390)
          wait_for(lambda: not history(), "Clear notification history")
          time.sleep(.15)
          capture("cleared")
          sp.run(["wtype", "-k", "Escape"], check=True, timeout=5)
          wait_for(lambda: popup_origin(capture("hidden")[2]) is None, "Calendar dismissal")
          clock_x, clock_y = width // 2, 8
          pointer.click(clock_x, clock_y)
          wait_for(lambda: popup_origin(capture("reopened")[2]) is not None, "Calendar reopening")
          for attempt in range(3):
              move(clock_x, clock_y)
              sp.run(["wtype", "-k", "Escape"], check=True, timeout=5)
              wait_for(lambda: popup_origin(capture("stationary-hidden")[2]) is None, "Stationary calendar dismissal")
              pointer_command("button 1")
              pointer_command("button 0")
              wait_for(lambda: popup_origin(capture("stationary-reopened")[2]) is not None,
                  f"Calendar reopening without pointer motion ({attempt})")
          for attempt in range(3):
              pointer_command("button 1")
              pointer_command("button 0")
              wait_for(lambda: popup_origin(capture("clock-hidden")[2]) is None, "Clock-click dismissal")
              pointer_command("button 1")
              pointer_command("button 0")
              wait_for(lambda: popup_origin(capture("clock-reopened")[2]) is not None,
                  f"Stationary clock toggle ({attempt})")
          pointer.click(0, height - 1)
          wait_for(lambda: popup_origin(capture("outside-dismissed")[2]) is None, "Outside-click dismissal")
          notify("Banner after calendar closed")
          wait_for(lambda: any(row.count(card_color) > 100 for row in capture("after-close")[2][:118]), "Closing calendar must restore banners")
          print("PASS: native date popup navigation, keyboard, history expansion/actions/replacement, dismissal, scrolling, Clear, stationary reopening/toggling, outside dismissal and calendar suppression")
      finally:
          client.close()
          pointer.close()
          terminate_processes([keyboard, service])
      PY
      ${dbusRun} python3 - clients <<'PY'
      import json
      import math
      import os
      from pathlib import Path
      import subprocess as sp
      import sys
      import tempfile
      import time
      from session_fixture import VirtualPointer, read_png, wait_until, write_wallpaper
      from wayland_ui import VirtualKeyboard

      bin_dir = Path(sys.argv[1]).resolve()
      root = Path(tempfile.mkdtemp(prefix="desktop-codex-check-", dir="/tmp"))
      print(f"Codex artifacts: {root}", flush=True)
      write_wallpaper(root / "wallpaper.png")
      (root / "panel.json").write_text(json.dumps({
          "left": [], "center": [],
          "right": [{"name": "gnome-codex", "source": "codex"}],
      }))
      env = dict(os.environ, WB_PANEL_DEMO="1", GSETTINGS_BACKEND="memory",
                 XDG_CACHE_HOME=str(root / "cache"), XDG_CONFIG_HOME=str(root / "config"),
                 XDG_STATE_HOME=str(root / "state"), G_DEBUG="fatal-criticals",
                 DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "no-system-bus"))
      log = root / "shell.log"
      current_scale = 1


      def run(*args):
          return sp.run(args, env=env, capture_output=True, text=True, check=True, timeout=10)


      def capture():
          filename = root / "screen.png"
          run(str(bin_dir / "desktop-zig"), "screenshot", "-o", "HEADLESS-1", str(filename))
          return read_png(filename)


      def visible():
          return at_scale(current_scale)


      def at_scale(scale, frame=None):
          width, height, rows = frame if frame is not None else capture()
          zoom = min(1, (width / scale - 16) / 340, (height / scale - 16) / 280)
          left = math.floor(width / scale - 340 * zoom - 8) * scale
          top = math.floor(min(32, max(8, height / scale - 280 * zoom - 8))) * scale
          y = int(top + 80 * zoom * scale)
          x = int(left + 10 * zoom * scale)
          outside = int(left - 20 * scale)
          return (rows[y][x * 3:x * 3 + 3] == bytes([54, 54, 58]) and
                  rows[y][outside * 3:outside * 3 + 3] == bytes([20, 40, 80]))


      def tooltip_visible():
          frame = capture()
          return (not at_scale(current_scale, frame) and
                  any(row.count(bytes([54, 54, 58])) > 60 for row in frame[2][33:120]))


      def usage_bars():
          # Usage widgets draw pace bars instead of a percent label. The demo
          # report is ahead of pace, so each bar has a neutral #9ca3af base.
          return any(row.count(bytes([156, 163, 175])) > 2 for row in capture()[2][:32])


      def wait_for(predicate, description):
          def alive():
              assert shell.poll() is None, log.read_text()[-8000:]
          wait_until(predicate, description, timeout=10, interval=.05, on_error=alive)


      run(str(bin_dir / "desktop-zig"), "output", "--output", "HEADLESS-1", "--scale", "1")
      keyboard = VirtualKeyboard(env)
      pointer = VirtualPointer(bin_dir / "desktop-pointer-fixture", env=env, delay=.07)
      with log.open("w") as output:
          shell = sp.Popen([str(bin_dir / "desktop-zig"), "serve", str(root / "wallpaper.png"),
                            str(root / "panel.json")], env=env, stdout=output, stderr=sp.STDOUT)
      try:
          wait_for(lambda: sp.run([str(bin_dir / "desktop-zig"), "ping"], env=env,
                                 capture_output=True).returncode == 0, "Codex shell ready")
          wait_for(usage_bars, "Codex panel usage bars")
          width, height, _ = capture()
          pointer.command(f"size {width} {height}")
          pointer.move(width - 30, 16)
          wait_for(tooltip_visible, "native panel tooltip on hover")
          pointer.click(width - 30, 16)
          wait_for(visible, "native Codex popup")
          pointer.click(width - 348 + 70, 32 + 242)
          assert visible(), "refresh closed the popup"
          keyboard.key(1, 0)
          wait_for(lambda: not visible(), "keyboard dismissal")
          pointer.click(width - 30, 16)
          wait_for(visible, "stationary reopening")
          keyboard.key(15, 0)
          keyboard.key(28, 0)
          assert visible(), "keyboard refresh closed the popup"
          pointer.click(width - 30, 16)
          wait_for(lambda: not visible(), "outside dismissal over the panel")
          pointer.move(width - 29, 16)
          wait_for(tooltip_visible, "panel tooltip after hovering again")
          pointer.click(width - 30, 16)
          wait_for(visible, "reopening after outside dismissal")
          for scale in (2, 4, 1):
              current_scale = scale
              run(str(bin_dir / "desktop-zig"), "output", "--output", "HEADLESS-1", "--scale", str(scale))
              wait_for(lambda: at_scale(scale), f"popup geometry at scale {scale}")
          pointer.click(1, height - 1)
          wait_for(lambda: not visible(), "outside dismissal after scaling")
          pointer.click(width - 30, 16)
          wait_for(visible, "popup before output removal")
          run("wlr-randr", "--output", "HEADLESS-1", "--off")
          time.sleep(.15)
          run("wlr-randr", "--output", "HEADLESS-1", "--on")
          wait_for(lambda: not visible(), "popup revoked with its output")
          wait_for(usage_bars, "replacement panel")
          pointer.click(width - 30, 16)
          wait_for(visible, "popup on replacement output")
          shell.terminate()
          assert shell.wait(timeout=10) == 0, log.read_text()[-8000:]
          assert not any(text in log.read_text() for text in ("CRITICAL", "panic:", "Segmentation")), log.read_text()[-8000:]
          print("PASS native panel tooltips, Codex refresh, keyboard, reopening, dismissal, scaling, output removal and teardown")
      finally:
          if shell.poll() is None:
              shell.terminate()
              shell.wait(timeout=10)
          pointer.close()
          keyboard.socket.close()
          run("wlr-randr", "--output", "HEADLESS-1", "--on", "--scale", "1")
      PY
    '';
}
