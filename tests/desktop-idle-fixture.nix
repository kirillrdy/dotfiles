{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-idle-check";
  pygobject = true;
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.wtype
  ];
  script =
    { desktop, dbusConfig, ... }:
    ''
      python3 - \
        --dbus-config ${dbusConfig} \
        --fixture ${desktop.tests}/bin/desktop-idle-fixture \
        --locker ${desktop.tests}/bin/desktop-lock-fixture \
        --compositor ${desktop}/bin/desktop-zig <<'PY'
      import argparse
      import os
      from pathlib import Path
      import select
      import signal
      import subprocess as sp
      import sys
      import tempfile
      import threading
      import time
      from gi.repository import Gio, GLib

      parser = argparse.ArgumentParser()
      parser.add_argument("--fixture", required=True)
      parser.add_argument("--locker", required=True)
      parser.add_argument("--compositor", default="desktop-zig")
      parser.add_argument("--dbus-daemon", default="dbus-daemon")
      parser.add_argument("--dbus-config")
      parser.add_argument("--wtype", default="wtype")
      args = parser.parse_args()
      root = Path(tempfile.mkdtemp(prefix="desktop-idle-check-", dir="/tmp"))
      print(f"Artifacts: {root}", flush=True)
      (root / "runtime").mkdir(mode=0o700)
      env = dict(os.environ)
      for key in ("DISPLAY", "WAYLAND_DISPLAY"):
          env.pop(key, None)
      env.update(XDG_RUNTIME_DIR=str(root / "runtime"), XDG_CONFIG_HOME=str(root / "config-home"),
                 WLR_BACKENDS="headless", WLR_RENDERER="pixman", WLR_HEADLESS_OUTPUTS="2",
                 WAYLAND_DEBUG="client", G_DEBUG="fatal-criticals")
      processes = []
      errors = []
      loop = GLib.MainLoop()
      thread = threading.Thread(target=loop.run, daemon=True)
      thread.start()


      def wait_until(check, description, timeout=12):
          deadline = time.monotonic() + timeout
          while not check():
              assert not errors, errors
              assert time.monotonic() < deadline, description
              time.sleep(0.02)


      def start(command, log):
          with (root / log).open("w") as output:
              process = sp.Popen(command, env=env, stdout=output, stderr=sp.STDOUT)
          processes.append(process)
          return process


      def text(log):
          return (root / log).read_text(errors="replace")


      def stopped(fd):
          poll = select.poll()
          poll.register(fd, select.POLLHUP)
          return bool(poll.poll(0))


      name = "org.freedesktop.login1"
      path = "/org/freedesktop/login1"
      interface = "org.freedesktop.login1.Manager"
      xml = f"""<node><interface name="{interface}">
      <method name="Inhibit"><arg type="s" direction="in"/><arg type="s" direction="in"/>
      <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="h" direction="out"/></method>
      <property name="PreparingForSleep" type="b" access="read"/>
      <signal name="PrepareForSleep"><arg type="b"/></signal></interface></node>"""


      def connection(address):
          conn = Gio.DBusConnection.new_for_address_sync(address,
              Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
              None, None)
          conn.set_exit_on_close(False)
          return conn


      class Logind:
          def __init__(self, address, preparing=False):
              self.conn = connection(address)
              self.preparing = preparing
              self.inhibitors = []
              self.delay = 0
              self.registration = self.conn.register_object(path,
                  Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], self.method, self.property, None)
              self.conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                  "RequestName", GLib.Variant("(su)", (name, 0)), GLib.VariantType("(u)"), 0, 3000, None)

          def method(self, conn, sender, obj, iface, method, parameters, invocation):
              try:
                  assert method == "Inhibit"
                  assert parameters.unpack() == ("sleep", "desktop-zig", "Lock the session before sleep", "delay")
                  read_fd, write_fd = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
                  self.inhibitors.append(read_fd)
                  def reply():
                      try:
                          fds = Gio.UnixFDList.new()
                          index = fds.append(write_fd)
                          invocation.return_value_with_unix_fd_list(GLib.Variant("(h)", (index,)), fds)
                      finally:
                          os.close(write_fd)
                      return False
                  if self.delay:
                      delay, self.delay = self.delay, 0
                      GLib.timeout_add(delay, reply)
                  else:
                      reply()
              except Exception as error:
                  errors.append(repr(error))
                  invocation.return_dbus_error("org.dotfiles.TestError", str(error))

          def property(self, *unused):
              return GLib.Variant("b", self.preparing)

          def prepare(self, value):
              self.preparing = value
              self.conn.emit_signal(None, path, interface, "PrepareForSleep", GLib.Variant("(b)", (value,)))
              self.conn.flush_sync(None)

          def release_name(self):
              self.conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                  "ReleaseName", GLib.Variant("(s)", (name,)), None, 0, 3000, None)


      helper = root / "locker"
      helper.write_text(f"""#!{sys.executable}
      import os, sys, time
      from pathlib import Path
      root = Path({str(root)!r})
      with (root / "attempts").open("a") as output: output.write("start\\n")
      time.sleep(float((root / "delay").read_text()))
      if (root / "fail").exists(): sys.exit(1)
      os.execv({args.locker!r}, [{args.locker!r}] + sys.argv[1:])
      """)
      helper.chmod(0o755)
      (root / "delay").write_text("0.45")


      def unlock(log, count):
          sp.run([args.wtype, "-k", "Shift_L"], env=env, check=True, capture_output=True, timeout=10)
          wait_until(lambda: ".modifiers(" in text(log).rsplit(".locked()", 1)[-1], "Lock keyboard focus")
          sp.run([args.wtype, "-s", "200", "-d", "10", "fixture-password", "-k", "Return"], env=env,
                 check=True, capture_output=True, timeout=10)
          wait_until(lambda: text(log).count("unlock_and_destroy()") >= count, "Lock authentication")
          time.sleep(0.1)


      def attempt_count():
          return (root / "attempts").read_text().count("start") if (root / "attempts").exists() else 0


      try:
          bus_address = "unix:path=" + str(root / "system-bus")
          bus_command = [args.dbus_daemon, "--nofork", "--print-address=1", "--address=" + bus_address,
                         "--config-file=" + args.dbus_config if args.dbus_config else "--session"]
          bus = sp.Popen(bus_command,
                         stdout=sp.PIPE, stderr=(root / "bus.log").open("w"), text=True)
          processes.append(bus)
          assert bus.stdout.readline().startswith("unix:"), text("bus.log")
          address = bus_address
          env["DBUS_SYSTEM_BUS_ADDRESS"] = address
          mock = Logind(address)
          mocks = [mock]
          compositor = start([args.compositor, "compositor-only"], "compositor.log")
          wait_until(lambda: list((root / "runtime").glob("wayland-*.lock")), "Compositor startup")
          env["WAYLAND_DISPLAY"] = next((root / "runtime").glob("wayland-*.lock")).stem

          idle = start([args.fixture, "250", str(helper)], "idle.log")
          wait_until(lambda: len(mock.inhibitors) == 1, "Initial inhibitor")
          initial = mock.inhibitors[0]
          wait_until(lambda: ".locked()" in text("idle.log"), "Idle locking")
          assert ".get_idle_notification(" in text("idle.log")
          assert "get_input_idle_notification" not in text("idle.log")
          assert not stopped(initial), "Idle locking released the suspend inhibitor"
          unlock("idle.log", 1)
          idle.terminate()
          assert idle.wait(timeout=5) == 0, text("idle.log")
          wait_until(lambda: stopped(initial), "Shutdown did not release inhibitor")

          service = start([args.fixture, "600000", str(helper)], "sleep.log")
          wait_until(lambda: len(mock.inhibitors) == 2, "Sleep inhibitor")
          current = mock.inhibitors[-1]
          spoof = connection(address)
          before = attempt_count()
          spoof.emit_signal(None, path, interface, "PrepareForSleep", GLib.Variant("(b)", (True,)))
          spoof.flush_sync(None)
          time.sleep(0.2)
          assert attempt_count() == before and not stopped(current)

          mock.prepare(True)
          wait_until(lambda: attempt_count() > before, "Before-sleep lock launch")
          time.sleep(0.15)
          assert not stopped(current), "Released inhibitor before compositor lock confirmation"
          wait_until(lambda: ".locked()" in text("sleep.log"), "Before-sleep lock confirmation")
          wait_until(lambda: stopped(current), "Readiness did not release inhibitor (or fd leaked into locker)")
          mock.prepare(False)
          wait_until(lambda: len(mock.inhibitors) == 3, "Resume did not reacquire inhibitor")
          current = mock.inhibitors[-1]
          before = attempt_count()
          mock.prepare(True)
          wait_until(lambda: stopped(current), "Already-ready locker did not release inhibitor")
          assert attempt_count() == before, "Duplicate locker on repeated sleep"
          unlock("sleep.log", 1)
          wait_until(lambda: text("sleep.log").count(".locked()") >= 2, "Unlock during pending suspend did not relock")
          assert attempt_count() == before + 1, "Unexpected lock count while preparing for sleep"
          mock.prepare(False)
          wait_until(lambda: len(mock.inhibitors) == 4, "Second resume inhibitor")
          unlock("sleep.log", 2)

          current = mock.inhibitors[-1]
          (root / "fail").touch()
          mock.prepare(True)
          wait_until(lambda: "lock readiness failed" in text("sleep.log"), "Missing-readiness failure")
          time.sleep(0.1)
          assert not stopped(current), "Failed lock released the inhibitor"
          (root / "fail").unlink()
          mock.prepare(False)

          mock.release_name()
          wait_until(lambda: stopped(current), "Logind owner loss did not release old inhibitor")
          mock2 = Logind(address)
          mocks.append(mock2)
          wait_until(lambda: len(mock2.inhibitors) == 1, "Logind restart did not reacquire inhibitor")
          assert not stopped(mock2.inhibitors[0])
          mock2.delay = 450
          mock2.prepare(True)
          wait_until(lambda: text("sleep.log").count(".locked()") >= 3, "Recovered logind did not lock")
          wait_until(lambda: stopped(mock2.inhibitors[0]), "Recovered lock did not release inhibitor")
          mock2.prepare(False)
          wait_until(lambda: len(mock2.inhibitors) == 2, "Delayed inhibitor request")
          pending = mock2.inhibitors[-1]
          mock2.release_name()
          mock3 = Logind(address)
          mocks.append(mock3)
          wait_until(lambda: len(mock3.inhibitors) == 1, "Replacement logind inhibitor")
          wait_until(lambda: stopped(pending), "Late inhibitor response leaked its fd")
          assert not stopped(mock3.inhibitors[0])
          unlock("sleep.log", 3)

          current = mock3.inhibitors[0]
          bus.terminate()
          bus.wait(timeout=5)
          wait_until(lambda: stopped(current), "System-bus disconnect leaked inhibitor")
          assert service.poll() is None, "System-bus disconnect killed idle management"
          bus = sp.Popen(bus_command, stdout=sp.PIPE, stderr=(root / "bus-restart.log").open("w"), text=True)
          processes.append(bus)
          assert bus.stdout.readline().startswith("unix:"), text("bus-restart.log")
          mock4 = Logind(address, preparing=True)
          mocks.append(mock4)
          wait_until(lambda: len(mock4.inhibitors) == 1, "System-bus restart did not reacquire inhibitor")
          wait_until(lambda: text("sleep.log").count(".locked()") >= 4, "Pending-sleep property did not lock after bus restart")
          wait_until(lambda: stopped(mock4.inhibitors[0]), "Restarted bus did not release inhibitor after readiness")
          mock4.prepare(False)
          wait_until(lambda: len(mock4.inhibitors) == 2, "Restarted bus resume inhibitor")
          unlock("sleep.log", 4)

          before = text("sleep.log").count(".locked()")
          attempts_before = attempt_count()
          mock4.prepare(True)
          wait_until(lambda: attempt_count() > attempts_before, "Final lock launch")
          service.terminate()
          assert service.wait(timeout=5) == 0, text("sleep.log")
          wait_until(lambda: text("sleep.log").count(".locked()") > before, "Locker died with shell")
          unlock("sleep.log", 5)
          mock4.prepare(False)

          session_address = "unix:path=" + str(root / "session-bus")
          session_bus = sp.Popen([args.dbus_daemon, "--nofork", "--print-address=1", "--address=" + session_address, "--session"],
                                 stdout=sp.PIPE, stderr=(root / "session-bus.log").open("w"), text=True)
          processes.append(session_bus)
          assert session_bus.stdout.readline().startswith("unix:"), text("session-bus.log")
          env["DBUS_SESSION_BUS_ADDRESS"] = session_address

          (root / "delay").write_text("0.05")
          portal_inhibited = [True]
          portal_conn = connection(session_address)
          portal_info = Gio.DBusNodeInfo.new_for_xml(
              "<node><interface name='org.dotfiles.Portal'>"
              "<method name='IdleInhibited'><arg type='b' direction='out'/></method>"
              "<signal name='IdleInhibitedChanged'><arg type='b'/></signal>"
              "</interface></node>"
          )
          def portal_method(conn, sender, obj, iface, method, parameters, invocation):
              if method == "IdleInhibited":
                  invocation.return_value(GLib.Variant("(b)", (portal_inhibited[0],)))
              else:
                  invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)
          portal_reg = portal_conn.register_object("/org/dotfiles/Portal", portal_info.interfaces[0], portal_method, None, None)
          assert portal_reg != 0
          portal_conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                "RequestName", GLib.Variant("(su)", ("org.freedesktop.portal.Desktop", 4)), None, 0, 3000, None)
          def set_portal_inhibited(value):
              portal_inhibited[0] = value
              portal_conn.emit_signal(None, "/org/dotfiles/Portal", "org.dotfiles.Portal", "IdleInhibitedChanged", GLib.Variant("(b)", (value,)))
              portal_conn.flush_sync(None)

          session_client = connection(session_address)
          session_other = connection(session_address)
          sp.run([args.wtype, "-k", "Shift_L"], env=env, check=True, capture_output=True, timeout=10)
          before_session_attempts = attempt_count()
          session_idle = start([args.fixture, "800", str(helper), "--session"], "session-inhibit.log")
          wait_until(lambda: len(mock4.inhibitors) == 3, "Session idle sleep inhibitor")
          wait_until(
              lambda: session_client.call_sync(
                  "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                  "NameHasOwner", GLib.Variant("(s)", ("org.freedesktop.ScreenSaver",)), None, 0, 3000, None
              ).unpack()[0],
              "ScreenSaver bus name",
          )
          cookie1 = session_client.call_sync(
              "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver",
              "Inhibit", GLib.Variant("(ss)", ("firefox", "Playing video")), None, 0, 3000, None
          ).unpack()[0]
          set_portal_inhibited(False)
          time.sleep(1.05)
          assert attempt_count() == before_session_attempts, f"ScreenSaver.Inhibit failed to prevent idle lock attempt ({before_session_attempts} -> {attempt_count()})"
          assert ".locked()" not in text("session-inhibit.log"), "ScreenSaver.Inhibit failed to prevent idle lock"
          session_client.call_sync(
              "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver",
              "SimulateUserActivity", None, None, 0, 3000, None
          )
          for bad_conn, bad_cookie, expected_err in ((session_other, cookie1, "AccessDenied"), (session_client, 999999, "InvalidArgs")):
              try:
                  bad_conn.call_sync(
                      "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver",
                      "UnInhibit", GLib.Variant("(u)", (bad_cookie,)), None, 0, 3000, None
                  )
                  raise AssertionError(f"Expected {expected_err}")
              except GLib.Error as err:
                  assert expected_err in str(err), err
          time.sleep(0.15)
          assert attempt_count() == before_session_attempts
          assert ".locked()" not in text("session-inhibit.log")
          session_client.call_sync(
              "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver",
              "UnInhibit", GLib.Variant("(u)", (cookie1,)), None, 0, 3000, None
          )
          wait_until(lambda: ".locked()" in text("session-inhibit.log"), "ScreenSaver.UnInhibit did not resume idle locking")

          transient = connection(session_address)
          transient.call_sync(
              "org.freedesktop.ScreenSaver", "/ScreenSaver", "org.freedesktop.ScreenSaver",
              "Inhibit", GLib.Variant("(ss)", ("chrome", "Blink Wake Lock")), None, 0, 3000, None
          )
          unlock("session-inhibit.log", 1)
          time.sleep(1.05)
          assert text("session-inhibit.log").count(".locked()") == 1, "/ScreenSaver inhibitor failed to prevent idle lock"
          transient.close_sync(None)
          wait_until(lambda: text("session-inhibit.log").count(".locked()") >= 2, "Sender disconnect did not release ScreenSaver inhibitor")

          set_portal_inhibited(True)
          time.sleep(0.05)
          unlock("session-inhibit.log", 2)
          time.sleep(1.05)
          assert text("session-inhibit.log").count(".locked()") == 2, "Portal idle inhibition failed to prevent idle lock"
          mock4.prepare(True)
          wait_until(lambda: text("session-inhibit.log").count(".locked()") >= 3, "Suspend failed to lock while idle-inhibited")
          wait_until(lambda: stopped(mock4.inhibitors[-1]), "Suspend inhibitor not released while idle-inhibited")
          mock4.prepare(False)
          wait_until(lambda: len(mock4.inhibitors) == 4, "Resume after idle-inhibited sleep")
          unlock("session-inhibit.log", 3)
          time.sleep(1.05)
          assert text("session-inhibit.log").count(".locked()") == 3, "Portal idle inhibition lost across suspend"
          set_portal_inhibited(False)
          wait_until(lambda: text("session-inhibit.log").count(".locked()") >= 4, "Portal uninhibition did not resume idle locking")

          session_idle.send_signal(signal.SIGUSR1)
          time.sleep(0.05)
          unlock("session-inhibit.log", 4)
          time.sleep(1.05)
          assert text("session-inhibit.log").count(".locked()") == 4, "Audio recording inhibition failed to prevent idle lock"
          session_idle.send_signal(signal.SIGUSR1)
          wait_until(lambda: text("session-inhibit.log").count(".locked()") >= 5, "Audio recording uninhibition did not resume idle locking")
          unlock("session-inhibit.log", 5)

          session_idle.terminate()
          assert session_idle.wait(timeout=5) == 0, text("session-inhibit.log")
          wait_until(lambda: stopped(mock4.inhibitors[-1]), "Session idle shutdown did not release inhibitor")
          for conn in (session_client, session_other, portal_conn):
              conn.close_sync(None)
          assert not errors, errors
          print("PASS: idle timeout, suspend readiness, inhibitor fd ownership, repeated cycles, failed locks, sender validation, logind/bus restart, pending sleep, stale replies, session inhibition and shell shutdown")
      finally:
          if "compositor" in locals() and compositor.poll() is None:
              compositor.terminate()
              compositor.wait(timeout=5)
          for process in reversed(processes):
              if process.poll() is None:
                  process.kill()
                  process.wait()
          loop.quit()
          thread.join(timeout=3)
          for mock in locals().get("mocks", []):
              for fd in mock.inhibitors:
                  os.close(fd)
      PY
    '';
}
