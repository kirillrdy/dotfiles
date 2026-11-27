{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-portal-check";
  pygobject = true;
  withDesktop = true;
  gtkEnv = true;
  fonts = true;
  cacheDir = true;
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.wlrctl
    pkgs.wtype
  ];
  script =
    {
      desktop,
      dbusRun,
      headlessScript,
      ...
    }:
    ''
      export XDG_CONFIG_HOME="$TMPDIR/config"
      export XDG_DATA_HOME="$TMPDIR/data"
      mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
      ${dbusRun} python3 - --binary ${desktop.tests}/bin/desktop-portal-fixture <<'PY'
      import argparse
      import os
      from pathlib import Path
      import select
      import signal
      import socket
      import subprocess
      import sys
      import struct
      import zlib
      import tempfile
      import threading
      import time
      import gi

      gi.require_version("Gio", "2.0")
      from gi.repository import Gio, GLib

      parser = argparse.ArgumentParser()
      parser.add_argument("--binary", required=True)
      args = parser.parse_args()
      root = Path(tempfile.mkdtemp(prefix="desktop-portal-check-", dir="/tmp"))
      print(f"Artifacts: {root}", flush=True)
      P = "/org/freedesktop/portal/desktop"
      PUB = "org.freedesktop.portal."
      IMP = "org.freedesktop.impl.portal."
      GTK = IMP + "desktop.gtk"
      WLR = IMP + "desktop.wlr"
      BUS = "org.freedesktop.DBus"
      context = GLib.MainContext.default()


      def wait(check, description, timeout=8):
          until = time.monotonic() + timeout
          while not check():
              while context.pending():
                  context.iteration(False)
              assert time.monotonic() < until, description
              time.sleep(0.002)


      def connection():
          return Gio.DBusConnection.new_for_address_sync(
              os.environ["DBUS_SESSION_BUS_ADDRESS"],
              Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
              None, None,
          )


      def call(conn, interface, method, params=None, path=P, fds=None, destination=PUB + "Desktop"):
          result = []
          def done(source, task):
              try:
                  result.append(source.call_with_unix_fd_list_finish(task))
              except GLib.Error as error:
                  result.append(error)
          conn.call_with_unix_fd_list(destination, path, interface, method, params, None, Gio.DBusCallFlags.NONE, 5000, fds, None, done)
          wait(lambda: result, f"{interface}.{method} reply")
          if isinstance(result[0], GLib.Error):
              raise result[0]
          return result[0]


      def rejected(function, description):
          try:
              function()
          except GLib.Error:
              return
          raise AssertionError(description)


      backend = connection()
      for name in (GTK, WLR, "org.freedesktop.login1", "org.freedesktop.Notifications", "org.dotfiles.PortalFixture"):
          backend.call_sync(BUS, "/org/freedesktop/DBus", BUS, "RequestName", GLib.Variant("(su)", (name, 4)), None, 0, 1000, None)
      registrations = []
      log = []
      held = {}
      sessions = {}
      notifications = []
      closed_notices = []
      notice_ids = []
      held_notifications = []
      application_actions = []
      next_notice = 10
      inhibitor_reads = []
      inhibitor_whats = []


      def signature_types(signature):
          def end(index):
              char = signature[index]
              if char == "a":
                  return end(index + 1)
              if char in "({":
                  close = ")" if char == "(" else "}"
                  index += 1
                  while signature[index] != close:
                      index = end(index)
              return index + 1
          index = 0
          while index < len(signature):
              stop = end(index)
              yield signature[index:stop]
              index = stop


      def interface_xml(name, methods, properties=()):
          xml = f'<node><interface name="{IMP}{name}">'
          for method, signature, result in methods:
              xml += f'<method name="{method}">'
              for typ in signature_types(signature):
                  xml += f'<arg type="{typ}" direction="in"/>'
              for typ in signature_types(result):
                  xml += f'<arg type="{typ}" direction="out"/>'
              xml += '</method>'
          for prop in properties:
              xml += f'<property name="{prop}" type="u" access="read"/>'
          return xml + '</interface></node>'


      def register(name, methods, properties=(), object_path=P):
          info = Gio.DBusNodeInfo.new_for_xml(interface_xml(name, methods, properties)).interfaces[0]
          identifier = backend.register_object(object_path, info, backend_call, lambda *_: GLib.Variant("u", 3), None)
          registrations.append(identifier)
          return identifier


      def backend_call(conn, sender, object_path, interface, method, params, invocation):
          values = params.unpack()
          log.append((interface, method, values))
          if interface == "org.freedesktop.Application":
              application_actions.append((method, values))
              invocation.return_value(None)
              return
          if interface == "org.freedesktop.Notifications":
              global next_notice
              if method == "Notify":
                  notifications.append(values)
                  native_id = values[1] or next_notice
                  if not values[1]: next_notice += 1
                  notice_ids.append(native_id)
                  if values[3] == "Slow notification":
                      held_notifications.append((invocation, native_id))
                  else:
                      invocation.return_value(GLib.Variant("(u)", (native_id,)))
              else:
                  closed_notices.append(values[0])
                  invocation.return_value(None)
              return
          if interface == "org.freedesktop.login1.Manager":
              assert values[0] in ("sleep", "sleep:idle"), values
              inhibitor_whats.append(values[0])
              read_fd, write_fd = os.pipe()
              inhibitor_reads.append(read_fd)
              descriptors = Gio.UnixFDList.new()
              index = descriptors.append(write_fd)
              os.close(write_fd)
              invocation.return_value_with_unix_fd_list(GLib.Variant("(h)", (index,)), descriptors)
              return
          if interface == IMP + "Request":
              old = held.pop(object_path, None)
              if old:
                  old.return_value(GLib.Variant("(ua{sv})", (1, {})))
              invocation.return_value(None)
              return
          if interface == IMP + "Session":
              sessions.pop(object_path, None)
              invocation.return_value(None)
              return
          if interface == IMP + "Settings":
              if method == "ReadAll":
                  invocation.return_value(GLib.Variant("(a{sa{sv}})", ({"org.freedesktop.appearance": {"color-scheme": GLib.Variant("u", 1)}},)))
              else:
                  invocation.return_value(GLib.Variant("(v)", (GLib.Variant("u", 1),)))
              return
          if interface == IMP + "Notification":
              notifications.append(values)
              invocation.return_value(None)
              return
          handle = values[0]
          register("Request", [("Close", "", "")], object_path=handle)
          if values[-1].get("hold"):
              held[handle] = invocation
              return
          if values[-1].get("fail"):
              invocation.return_dbus_error("org.freedesktop.portal.Error.Failed", "fixture backend failure")
              return
          results = {}
          if interface == IMP + "Screenshot":
              results = {"uri": GLib.Variant("s", "file:///tmp/screenshot.png")}
          elif interface == IMP + "ScreenCast":
              handle = values[1]
              if method == "CreateSession":
                  sessions[handle] = register("Session", [("Close", "", "")], object_path=handle)
              elif method == "Start":
                  results = {"streams": GLib.Variant("a(ua{sv})", [(777, {"size": GLib.Variant("(ii)", (1920, 1080))})])}
          invocation.return_value(GLib.Variant("(ua{sv})", (0, results)))


      register("Screenshot", [("Screenshot", "ossa{sv}", "ua{sv}")])
      register("ScreenCast", [("CreateSession", "oosa{sv}", "ua{sv}"), ("SelectSources", "oosa{sv}", "ua{sv}"), ("Start", "oossa{sv}", "ua{sv}")], ["AvailableSourceTypes", "AvailableCursorModes"])
      register("Settings", [("Read", "ss", "v"), ("ReadAll", "as", "a{sa{sv}}")])
      register("Notification", [("AddNotification", "ssa{sv}", ""), ("RemoveNotification", "ss", "")])
      inhibit_info = Gio.DBusNodeInfo.new_for_xml('<node><interface name="org.freedesktop.login1.Manager"><method name="Inhibit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="h" direction="out"/></method></interface></node>').interfaces[0]
      registrations.append(backend.register_object("/org/freedesktop/login1", inhibit_info, backend_call, None, None))
      notice_xml = interface_xml("Placeholder", [("Notify", "susssasa{sv}i", "u"), ("CloseNotification", "u", "")]).replace(IMP + "Placeholder", "org.freedesktop.Notifications")
      notice_info = Gio.DBusNodeInfo.new_for_xml(notice_xml).interfaces[0]
      registrations.append(backend.register_object("/org/freedesktop/Notifications", notice_info, backend_call, None, None))
      app_xml = interface_xml("Placeholder", [("Activate", "a{sv}", ""), ("ActivateAction", "sava{sv}", "")]).replace(IMP + "Placeholder", "org.freedesktop.Application")
      registrations.append(backend.register_object("/org/dotfiles/PortalFixture", Gio.DBusNodeInfo.new_for_xml(app_xml).interfaces[0], backend_call, None, None))
      client = connection()
      other = connection()
      responses = {}
      foreign_responses = []
      settings_changed = []
      notification_actions = []
      foreign_actions = []
      closed_sessions = []
      client.signal_subscribe(PUB + "Desktop", PUB + "Request", "Response", None, None, 0, lambda conn, sender, path, interface, signal, params: responses.__setitem__(path, params.unpack()))
      other.signal_subscribe(PUB + "Desktop", PUB + "Request", "Response", None, None, 0, lambda *event: foreign_responses.append(event))
      client.signal_subscribe(PUB + "Desktop", PUB + "Settings", "SettingChanged", P, None, 0, lambda *event: settings_changed.append(event[-1].unpack()))
      client.signal_subscribe(PUB + "Desktop", PUB + "Notification", "ActionInvoked", P, None, 0, lambda *event: notification_actions.append(event[-1].unpack()))
      other.signal_subscribe(PUB + "Desktop", PUB + "Notification", "ActionInvoked", P, None, 0, lambda *event: foreign_actions.append(event[-1].unpack()))
      client.signal_subscribe(PUB + "Desktop", PUB + "Session", "Closed", None, None, 0, lambda conn, sender, path, *event: closed_sessions.append(path))
      for directory in ("home", "config", "data/fonts", "cache"):
          (root / directory).mkdir(parents=True)
      env = dict(os.environ, XDG_RUNTIME_DIR=str(root), HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"), XDG_CACHE_HOME=str(root / "cache"), GSETTINGS_BACKEND="keyfile", DBUS_SYSTEM_BUS_ADDRESS=os.environ["DBUS_SESSION_BUS_ADDRESS"], G_DEBUG="fatal-criticals")
      env.pop("DISPLAY", None)
      env.pop("WAYLAND_DISPLAY", None)
      output = (root / "broker.log").open("w")
      process = subprocess.Popen([args.binary, "portal"], env=env, stdout=output, stderr=output)


      def request(interface, method, signature, values, conn=client, expect_response=True, fds=None):
          reply, _ = call(conn, PUB + interface, method, GLib.Variant(signature, values), fds=fds)
          handle = reply.unpack()[0]
          if expect_response:
              wait(lambda: handle in responses, method + " Response")
              return handle, responses[handle]
          return handle


      try:
          def owned():
              reply = client.call_sync(BUS, "/org/freedesktop/DBus", BUS, "NameHasOwner", GLib.Variant("(s)", (PUB + "Desktop",)), None, 0, 1000, None)
              return reply.unpack()[0]
          wait(owned, "native broker owns public name")
          assert process.poll() is None, (root / "broker.log").read_text()
          call(client, "org.freedesktop.host.portal.Registry", "Register", GLib.Variant("(sa{sv})", ("org.dotfiles.PortalFixture", {})))
          reply, _ = call(client, PUB + "Settings", "ReadOne", GLib.Variant("(ss)", ("org.freedesktop.appearance", "color-scheme")))
          assert reply.get_child_value(0).get_variant().get_uint32() == 0
          reply, _ = call(client, PUB + "Settings", "Read", GLib.Variant("(ss)", ("org.freedesktop.appearance", "color-scheme")))
          assert reply.get_child_value(0).get_variant().get_variant().get_uint32() == 0
          reply, _ = call(client, PUB + "Settings", "ReadAll", GLib.Variant("(as)", (["org.freedesktop.*"],)))
          assert set(reply.unpack()[0]) == {"org.freedesktop.appearance"}
          rejected(lambda: call(client, PUB + "Settings", "ReadOne", GLib.Variant("(ss)", ("org.gnome.desktop.interface", "does-not-exist"))), "unknown setting accepted")
          setter = subprocess.Popen([sys.executable, "-c", "from gi.repository import Gio; s=Gio.Settings.new('org.gnome.desktop.interface'); assert s.set_string('color-scheme', 'prefer-dark'); Gio.Settings.sync()"], env=env, stdout=output, stderr=output)
          wait(lambda: setter.poll() is not None, "settings writer exits")
          assert setter.returncode == 0, (root / "broker.log").read_text()
          wait(lambda: any(event == ("org.freedesktop.appearance", "color-scheme", 1) for event in settings_changed), "native appearance change pushed")
          (root / "data/fonts/fixture-change").write_text("font directory changed")
          wait(lambda: any(event[0] == "org.gnome.fontconfig" for event in settings_changed), "font serial invalidated")
          assert not any(entry[0] == IMP + "Settings" for entry in log), "settings still used GTK backend"
          print("PASS native settings reads, namespace filters, appearance updates and font invalidation", flush=True)
          rejected(lambda: request("Screenshot", "Screenshot", "(sa{sv})", ("", {"handle_token": GLib.Variant("s", "bad/path")})), "invalid token accepted")
          rejected(lambda: request("Screenshot", "Screenshot", "(sa{sv})", ("", {"interactive": GLib.Variant("s", "yes")})), "invalid interactive option accepted")
          _, implicit = request("ScreenCast", "CreateSession", "(a{sv})", ({},))
          call(client, PUB + "Session", "Close", path=implicit[1]["session_handle"])
          rejected(lambda: request("ScreenCast", "CreateSession", "(a{sv})", ({"session_handle_token": GLib.Variant("u", 1)},)), "non-string session token accepted")
          _, response = request("ScreenCast", "CreateSession", "(a{sv})", ({"session_handle_token": GLib.Variant("s", "cast")},))
          session = response[1]["session_handle"]
          rejected(lambda: call(other, PUB + "Session", "Close", path=session), "foreign client closed session")
          rejected(lambda: call(client, PUB + "ScreenCast", "OpenPipeWireRemote", GLib.Variant("(oa{sv})", (session, {}))), "unstarted session opened remote")
          rejected(lambda: request("ScreenCast", "Start", "(osa{sv})", (session, "", {})), "Start accepted before SelectSources")
          for options in ({"types": GLib.Variant("u", 2)}, {"types": GLib.Variant("s", "screen")}, {"cursor_mode": GLib.Variant("u", 4)}, {"multiple": GLib.Variant("s", "yes")}):
              rejected(lambda: request("ScreenCast", "SelectSources", "(oa{sv})", (session, options)), "invalid source options accepted")
          request("ScreenCast", "SelectSources", "(oa{sv})", (session, {"types": GLib.Variant("u", 1), "cursor_mode": GLib.Variant("u", 2)}))
          rejected(lambda: request("ScreenCast", "SelectSources", "(oa{sv})", (session, {})), "sources selected twice")
          call(client, PUB + "Session", "Close", path=session)
          wait(lambda: session in closed_sessions, "native session closed")
          assert not any(entry[0] in (IMP + "Screenshot", IMP + "ScreenCast") for entry in log), "capture forwarded to WLR"
          print("PASS native screencast sequencing, option validation and session ownership", flush=True)

          call(client, PUB + "Notification", "AddNotification", GLib.Variant("(sa{sv})", ("notice", {"title": GLib.Variant("s", "Native portal"), "body": GLib.Variant("s", "plain <body> & text"), "priority": GLib.Variant("s", "high"), "default-action": GLib.Variant("s", "default")})))
          wait(lambda: notifications, "native notification delivered")
          assert notifications[0][0] == "org.dotfiles.PortalFixture"
          assert notifications[0][3:5] == ("Native portal", "plain &lt;body&gt; &amp; text"), notifications[0]
          assert notifications[0][6]["urgency"] == 2
          call(other, "org.freedesktop.host.portal.Registry", "Register", GLib.Variant("(sa{sv})", ("org.dotfiles.PortalFixture", {})))
          backend.emit_signal(None, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "ActionInvoked", GLib.Variant("(us)", (10, "default")))
          wait(lambda: notification_actions, "notification action forwarded")
          assert notification_actions == [("notice", "default", [])], notification_actions
          assert not foreign_actions, "notification action leaked to another client with the same app ID"
          call(client, PUB + "Notification", "AddNotification", GLib.Variant("(sa{sv})", ("notice", {"title": GLib.Variant("s", "Replaced")})))
          wait(lambda: len(notifications) == 2, "notification replaced")
          assert notifications[-1][1] == 10, notifications
          call(client, PUB + "Notification", "RemoveNotification", GLib.Variant("(s)", ("notice",)))
          wait(lambda: 10 in closed_notices, "notification removed")
          assert not any(entry[0] == IMP + "Notification" for entry in log), "notification still used GTK backend"
          print("PASS native notification delivery, markup, urgency, replacement, removal and action isolation", flush=True)
          def png_chunk(kind, data):
              return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
          png = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)) + png_chunk(b"IDAT", zlib.compress(b"\0\xff\0\0\xff")) + png_chunk(b"IEND", b"")
          icon = Gio.BytesIcon.new(GLib.Bytes.new(png)).serialize()
          buttons = GLib.Variant("aa{sv}", [{"label": GLib.Variant("s", "Open"), "action": GLib.Variant("s", "app.open"), "target": GLib.Variant("s", "payload")}])
          call(client, PUB + "Notification", "AddNotification", GLib.Variant("(sa{sv})", ("image", {"title": GLib.Variant("s", "Image"), "icon": icon, "buttons": buttons})))
          wait(lambda: len(notifications) == 3, "image notification delivered")
          image_id = notice_ids[-1]
          assert "image-data" in notifications[-1][6], notifications[-1]
          image = notifications[-1][6]["image-data"]
          assert 0 < image[0] <= 128 and 0 < image[1] <= 128 and image[-1]
          backend.emit_signal(None, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "ActionInvoked", GLib.Variant("(us)", (image_id, "button0")))
          wait(lambda: any(event == ("ActivateAction", ("open", ["payload"], {})) for event in application_actions), "application action activated with target")
          call(client, PUB + "Notification", "AddNotification", GLib.Variant("(sa{sv})", ("slow", {"title": GLib.Variant("s", "Slow notification")})))
          wait(lambda: held_notifications, "Notify reply held")
          call(client, PUB + "Notification", "RemoveNotification", GLib.Variant("(s)", ("slow",)))
          pending, slow_id = held_notifications.pop()
          pending.return_value(GLib.Variant("(u)", (slow_id,)))
          wait(lambda: slow_id in closed_notices, "removal during Notify closes returned ID")
          before_actions = len(notification_actions)
          backend.call_sync(BUS, "/org/freedesktop/DBus", BUS, "ReleaseName", GLib.Variant("(s)", ("org.freedesktop.Notifications",)), None, 0, 1000, None)
          next_notice = image_id
          backend.call_sync(BUS, "/org/freedesktop/DBus", BUS, "RequestName", GLib.Variant("(su)", ("org.freedesktop.Notifications", 4)), None, 0, 1000, None)
          count_before = len(notifications)
          call(other, PUB + "Notification", "AddNotification", GLib.Variant("(sa{sv})", ("after-restart", {"title": GLib.Variant("s", "New owner")})))
          wait(lambda: len(notifications) > count_before, "notification after service restart")
          backend.emit_signal(None, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "ActionInvoked", GLib.Variant("(us)", (image_id, "default")))
          wait(lambda: foreign_actions, "reused ID belongs to new owner")
          assert foreign_actions == [("after-restart", "default", [])], foreign_actions
          assert len(notification_actions) == before_actions, "stale owner received reused notification ID"
          print("PASS notification images, application actions, pending removal and daemon restart isolation", flush=True)

          reply, _ = call(client, PUB + "NetworkMonitor", "GetStatus")
          assert set(reply.unpack()[0]) == {"available", "metered", "connectivity"}
          reply, _ = call(client, PUB + "NetworkMonitor", "CanReach", GLib.Variant("(su)", ("localhost", 80)))
          assert isinstance(reply.unpack()[0], bool)
          portal_idle_changes = []
          client.signal_subscribe(
              None,
              "org.dotfiles.Portal",
              "IdleInhibitedChanged",
              "/org/dotfiles/Portal",
              None,
              0,
              lambda _c, _s, _p, _i, _sig, params: portal_idle_changes.append(params.unpack()[0]),
          )
          assert call(client, "org.dotfiles.Portal", "IdleInhibited", path="/org/dotfiles/Portal")[0].unpack() == (False,)
          sleep_only = request("Inhibit", "Inhibit", "(sua{sv})", ("", 4, {"reason": GLib.Variant("s", "fixture audio")}), expect_response=False)
          wait(lambda: inhibitor_reads, "sleep-only logind inhibitor acquired")
          assert inhibitor_whats == ["sleep"], inhibitor_whats
          sleep_fd = inhibitor_reads[-1]
          assert call(client, "org.dotfiles.Portal", "IdleInhibited", path="/org/dotfiles/Portal")[0].unpack() == (False,)
          assert not portal_idle_changes, portal_idle_changes
          call(client, PUB + "Request", "Close", path=sleep_only)
          wait(lambda: select.select([sleep_fd], [], [], 0)[0], "Close releases sleep-only logind inhibitor")
          assert os.read(sleep_fd, 1) == b""
          os.close(sleep_fd)
          before_reads = len(inhibitor_reads)
          handle = request("Inhibit", "Inhibit", "(sua{sv})", ("", 12, {"reason": GLib.Variant("s", "fixture playback")}), expect_response=False)
          wait(lambda: len(inhibitor_reads) > before_reads, "logind inhibitor acquired")
          assert inhibitor_whats == ["sleep", "sleep:idle"], inhibitor_whats
          wait(lambda: portal_idle_changes == [True], "portal idle inhibition signal emitted")
          assert call(client, "org.dotfiles.Portal", "IdleInhibited", path="/org/dotfiles/Portal")[0].unpack() == (True,)
          for _ in range(20):
              while context.pending(): context.iteration(False)
              time.sleep(0.002)
          read_fd = inhibitor_reads[-1]
          assert not select.select([read_fd], [], [], 0)[0], "inhibitor released too early"
          call(client, PUB + "Request", "Close", path=handle)
          wait(lambda: select.select([read_fd], [], [], 0)[0], "Close releases logind inhibitor")
          wait(lambda: portal_idle_changes == [True, False], "portal idle uninhibition signal emitted")
          assert call(client, "org.dotfiles.Portal", "IdleInhibited", path="/org/dotfiles/Portal")[0].unpack() == (False,)
          assert os.read(read_fd, 1) == b""
          os.close(read_fd)
          print("PASS native logind and session idle inhibition and release on Close", flush=True)
          transient = connection()
          reply, _ = call(transient, PUB + "ScreenCast", "CreateSession", GLib.Variant("(a{sv})", ({},)))
          transient.close_sync(None)
          assert not foreign_responses, "Response broadcast to another client"
          print("PASS notifications, native network status and disconnect cleanup", flush=True)
          sandbox_code = """
      from gi.repository import Gio, GLib
      connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
      try:
          connection.call_sync('org.freedesktop.portal.Desktop', '/org/freedesktop/portal/desktop', 'org.freedesktop.portal.NetworkMonitor', 'GetStatus', None, None, 0, 3000, None)
      except GLib.Error as error:
          assert 'NotAllowed' in str(error), error
      else:
          raise AssertionError('sandboxed client was accepted without mediation')
      """
          sandbox = subprocess.Popen([sys.executable, "-c", sandbox_code], env=dict(os.environ, SNAP="/snap/portal-fixture"), stdout=output, stderr=output)
          wait(lambda: sandbox.poll() is not None, "sandbox client rejected")
          assert sandbox.returncode == 0, (root / "broker.log").read_text()
          print("PASS sandbox clients cannot obtain unmediated host access", flush=True)
          process.send_signal(signal.SIGTERM)
          wait(lambda: process.poll() is not None, "broker shutdown")
          assert process.returncode == 0, (root / "broker.log").read_text()
          print("PASS clean shutdown with checked Zig allocation ownership", flush=True)
      finally:
          if process.poll() is None:
              process.terminate()
              process.wait(timeout=5)
          output.close()
          for conn in (client, other, backend):
              conn.close_sync(None)
      PY
      ${dbusRun} python3 - --binary ${desktop.tests}/bin/desktop-portal-fixture <<'PY'
      import argparse
      import json
      import os
      from pathlib import Path
      import signal
      import subprocess
      import sys
      import tempfile
      import time
      from urllib.parse import parse_qs, unquote, urlsplit
      import gi

      gi.require_version("Gio", "2.0")
      from gi.repository import Gio, GLib

      parser = argparse.ArgumentParser()
      parser.add_argument("--binary", required=True)
      args = parser.parse_args()
      root = Path(tempfile.mkdtemp(prefix="desktop-portal-email-", dir="/tmp"))
      print(f"Artifacts: {root}", flush=True)
      for directory in ("home", "config", "cache", "data/applications", "system-data"):
          (root / directory).mkdir(parents=True)
      env = dict(os.environ, HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"), XDG_CACHE_HOME=str(root / "cache"), XDG_DATA_HOME=str(root / "data"), XDG_DATA_DIRS=str(root / "system-data"), XDG_RUNTIME_DIR=str(root), GSETTINGS_BACKEND="memory", G_DEBUG="fatal-criticals")
      PUB = "org.freedesktop.portal."
      P = "/org/freedesktop/portal/desktop"
      BUS = "org.freedesktop.DBus"
      APP = "org.dotfiles.PortalMailFixture"
      context = GLib.MainContext.default()
      process = None
      output = (root / "broker.log").open("w")


      def wait(check, description, timeout=10):
          until = time.monotonic() + timeout
          while not check():
              while context.pending():
                  context.iteration(False)
              assert time.monotonic() < until, description
              time.sleep(0.005)


      def connection():
          return Gio.DBusConnection.new_for_address_sync(os.environ["DBUS_SESSION_BUS_ADDRESS"], Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)


      client = connection()
      other = connection()
      handler = connection()
      responses = {}
      client.signal_subscribe(PUB + "Desktop", PUB + "Request", "Response", None, None, 0, lambda conn, sender, path, interface, signal, params: responses.__setitem__(path, params.unpack()))


      def call(conn, interface, method, params=None, path=P, fds=None):
          results = []

          def done(source, task):
              try:
                  results.append(source.call_with_unix_fd_list_finish(task)[0])
              except GLib.Error as error:
                  results.append(error)

          conn.call_with_unix_fd_list(PUB + "Desktop", path, interface, method, params, None, 0, 5000, fds, None, done)
          wait(lambda: results, method + " reply")
          if isinstance(results[0], GLib.Error):
              raise results[0]
          return results[0]


      def rejected(function):
          try:
              function()
          except GLib.Error as error:
              remote = Gio.DBusError.get_remote_error(error)
              assert remote and remote.startswith(PUB + "Error."), error
              return
          raise AssertionError("invalid operation accepted")


      def owned(name):
          return client.call_sync(BUS, "/org/freedesktop/DBus", BUS, "NameHasOwner", GLib.Variant("(s)", (name,)), None, 0, 1000, None).unpack()[0]


      def start():
          global process
          responses.clear()
          process = subprocess.Popen([args.binary, "portal"], env=env, stdout=output, stderr=output)
          wait(lambda: owned(PUB + "Desktop"), "broker starts")


      def stop():
          process.send_signal(signal.SIGTERM)
          wait(lambda: process.poll() is not None, "broker stops")
          assert process.returncode == 0, (root / "broker.log").read_text()
          wait(lambda: not owned(PUB + "Desktop"), "broker releases name")


      serial = 0


      def compose(options=None, conn=client, fds=None, response=True):
          global serial
          serial += 1
          opts = dict(options or {})
          opts.setdefault("handle_token", GLib.Variant("s", f"email{serial}"))
          result = call(conn, PUB + "Email", "ComposeEmail", GLib.Variant("(sa{sv})", ("", opts)), fds=fds)
          handle = result.unpack()[0]
          if response:
              wait(lambda: handle in responses, "email Response")
              return responses[handle]
          return handle


      mimeapps = root / "config/mimeapps.list"
      desktop = root / f"data/applications/{APP}.desktop"
      capture = root / "capture.py"
      captured = root / "captured.json"
      capture.write_text("import json, os, pathlib, sys\n" + f"pathlib.Path({str(captured)!r}).write_text(json.dumps([sys.argv[1:], os.getenv('XDG_ACTIVATION_TOKEN'), os.getenv('DESKTOP_STARTUP_ID')]))\n")
      desktop.write_text(f"[Desktop Entry]\nType=Application\nName=Fixture mail\nExec={sys.executable} {capture} %u\nMimeType=x-scheme-handler/mailto;\nNoDisplay=true\nStartupNotify=true\nDBusActivatable=false\n")

      try:
          start()
          assert compose() == (2, {}), "missing handler should fail asynchronously"
          stop()
          mimeapps.write_text(f"[Default Applications]\nx-scheme-handler/mailto={APP}.desktop;\n")
          start()
          version = call(client, "org.freedesktop.DBus.Properties", "Get", GLib.Variant("(ss)", (PUB + "Email", "version"))).unpack()[0]
          assert version == 4, version
          one = root / "日本語 & report?.txt"
          two = root / "second # file.txt"
          one.write_text("attachment one\n")
          two.write_text("attachment two\n")
          descriptors = Gio.UnixFDList.new()
          for filename in (one, two):
              fd = os.open(filename, os.O_RDONLY)
              descriptors.append(fd)
              os.close(fd)
          options = {"address": GLib.Variant("s", "first+tag@example.org"), "addresses": GLib.Variant("as", ["second@host"]), "cc": GLib.Variant("as", ["c&d@example.org"]), "bcc": GLib.Variant("as", ["private@example.org"]), "subject": GLib.Variant("s", "日本語 &bcc=extra"), "body": GLib.Variant("s", "first\nsecond?body=extra"), "activation_token": GLib.Variant("s", "fixture-token"), "attachment_fds": GLib.Variant("ah", [0, 1])}
          assert compose(options, fds=descriptors) == (0, {})
          wait(captured.exists, "mail handler receives URI")
          argv, token, startup_id = json.loads(captured.read_text())
          assert len(argv) == 1, argv
          uri = urlsplit(argv[0])
          assert uri.scheme == "mailto" and unquote(uri.path) == "first+tag@example.org,second@host", uri
          values = parse_qs(uri.query)
          attachments = values.pop("attachment")
          assert [unquote(urlsplit(uri).path) for uri in attachments] == [str(one), str(two)], attachments
          assert all(urlsplit(uri).scheme == "file" for uri in attachments)
          assert values == {"cc": ["c&d@example.org"], "bcc": ["private@example.org"], "subject": ["日本語 &bcc=extra"], "body": ["first\nsecond?body=extra"]}, values
          assert token == startup_id == "fixture-token", (token, startup_id)
          for attachment, content in zip(attachments, ("attachment one\n", "attachment two\n")):
              assert Path(unquote(urlsplit(attachment).path)).read_text() == content
          assert not owned("org.freedesktop.impl.portal.desktop.gtk"), "email used GTK backend"
          for invalid in ({"address": GLib.Variant("s", "bad@example.org?bcc=extra")}, {"cc": GLib.Variant("as", ["bad@-host"])}, {"subject": GLib.Variant("s", "first\nsecond")}, {"subject": GLib.Variant("s", "a" * 201)}, {"body": GLib.Variant("b", True)}, {"activation_token": GLib.Variant("b", True)}, {"attachment_fds": GLib.Variant("as", [])}, {"attachment_fds": GLib.Variant("ah", [0])}):
              rejected(lambda: compose(invalid))
          for indices in ([2], [-1]):
              rejected(lambda: compose({"attachment_fds": GLib.Variant("ah", indices)}, fds=descriptors))
          for filename in (root, root / "deleted"):
              if filename != root:
                  filename.write_text("deleted attachment")
              fd = os.open(filename, os.O_RDONLY)
              invalid_fds = Gio.UnixFDList.new()
              invalid_fds.append(fd)
              os.close(fd)
              if filename != root:
                  filename.unlink()
              rejected(lambda: compose({"attachment_fds": GLib.Variant("ah", [0])}, fds=invalid_fds))
          print("PASS native email recipients, Unicode/escaped headers, two FD attachments, activation token, invalid options and missing handler", flush=True)
          stop()

          desktop.write_text(desktop.read_text().replace("DBusActivatable=false", "DBusActivatable=true"))
          handler.call_sync(BUS, "/org/freedesktop/DBus", BUS, "RequestName", GLib.Variant("(su)", (APP, 4)), None, 0, 1000, None)
          pending = []
          launches = []

          def opened(conn, sender, path, interface, method, params, invocation):
              launches.append(params.unpack())
              pending.append(invocation)

          info = Gio.DBusNodeInfo.new_for_xml('<node><interface name="org.freedesktop.Application"><method name="Open"><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/></method></interface></node>').interfaces[0]
          handler.register_object("/org/dotfiles/PortalMailFixture", info, opened, None, None)
          start()
          handle = compose({"activation_token": GLib.Variant("s", "dbus-token")}, response=False)
          wait(lambda: pending, "D-Bus handler receives launch")
          assert "dbus-token" in launches[-1][1].values(), launches[-1]
          rejected(lambda: call(other, PUB + "Request", "Close", path=handle))
          call(client, PUB + "Request", "Close", path=handle)
          pending.pop().return_value(None)
          call(client, PUB + "NetworkMonitor", "GetStatus")
          assert handle not in responses, "closed email request emitted Response"
          handle = compose(response=False)
          wait(lambda: pending, "second D-Bus launch")
          pending.pop().return_value(None)
          wait(lambda: handle in responses, "successful D-Bus launch")
          assert responses[handle] == (0, {}), responses[handle]
          transient = connection()
          compose(conn=transient, response=False)
          wait(lambda: pending, "disconnected D-Bus launch")
          transient.close_sync(None)
          pending.pop().return_value(None)
          compose(response=False)
          wait(lambda: pending, "pending launch before shutdown")
          stop()
          pending.pop().return_value(None)
          print("PASS D-Bus mail activation token, launch completion, request ownership, cancellation, disconnect and shutdown with checked allocation ownership", flush=True)
      finally:
          if process is not None and process.poll() is None:
              process.terminate()
              process.wait(timeout=5)
          output.close()
          client.close_sync(None)
          other.close_sync(None)
          handler.close_sync(None)
      PY

      ${headlessScript}
      export NO_AT_BRIDGE=1
      export GTK_USE_PORTAL=0
      export GIO_USE_VFS=local
      export G_DEBUG=fatal-criticals
      chooser_files="$TMPDIR/chooser-files"
      mkdir -p "$chooser_files"
      for name in one.txt 日本語.txt report.txt; do
        printf 'fixture\n' > "$chooser_files/$name"
      done
      GSETTINGS_BACKEND=memory ${dbusRun} ${desktop.tests}/bin/desktop-portal-chooser-fixture "$chooser_files"
      ${dbusRun} python3 - --binary ${desktop.tests}/bin/desktop-portal-fixture <<'PY'
      import argparse
      import os
      from pathlib import Path
      import signal
      import subprocess as sp
      import tempfile
      import time
      import gi
      from wayland_ui import WaylandUI

      gi.require_version("Gio", "2.0")
      from gi.repository import Gio, GLib

      parser = argparse.ArgumentParser()
      parser.add_argument("--binary", required=True)
      args = parser.parse_args()
      root = Path(tempfile.mkdtemp(prefix="desktop-portal-chooser-", dir="/tmp"))
      print(f"Artifacts: {root}", flush=True)
      for name in ("config", "cache", "data", "home"):
          (root / name).mkdir()
      selected = root / "selected file.txt"
      selected.write_text("native chooser fixture\n")
      (root / "home" / ".face").write_text("account picture fixture\n")
      env = dict(os.environ, HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"), XDG_CACHE_HOME=str(root / "cache"), XDG_DATA_HOME=str(root / "data"), GTK_USE_PORTAL="0", GIO_USE_VFS="local", NO_AT_BRIDGE="1", GSETTINGS_BACKEND="memory", G_DEBUG="fatal-criticals")
      PUB = "org.freedesktop.portal."
      P = "/org/freedesktop/portal/desktop"
      context = GLib.MainContext.default()


      def wait(check, description, timeout=12):
          until = time.monotonic() + timeout
          while not check():
              while context.pending():
                  context.iteration(False)
              if time.monotonic() >= until:
                  ui.run("grim", str(Path(os.environ.get("TMPDIR", root)) / "portal-ui-failure.png"), check=False)
                  raise AssertionError(description + "\n" + (root / "broker.log").read_text())
              time.sleep(0.01)


      def connection():
          return Gio.DBusConnection.new_for_address_sync(os.environ["DBUS_SESSION_BUS_ADDRESS"], Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)


      def call(conn, interface, method, params=None, path=P):
          result = []
          def finished(source, task):
              try:
                  result.append(source.call_finish(task))
              except GLib.Error as error:
                  result.append(error)
          conn.call(PUB + "Desktop", path, interface, method, params, None, 0, 5000, None, finished)
          wait(lambda: result, method + " reply")
          if isinstance(result[0], GLib.Error):
              raise result[0]
          return result[0]


      def rejected(function):
          try:
              function()
          except GLib.Error:
              return
          raise AssertionError("invalid operation accepted")


      ui = WaylandUI(env)
      window = ui.window


      client = connection()
      other = connection()
      responses = {}
      client.signal_subscribe(PUB + "Desktop", PUB + "Request", "Response", None, None, 0, lambda conn, sender, path, interface, signal, params: responses.__setitem__(path, params.unpack()))
      output = (root / "broker.log").open("w")
      process = sp.Popen([args.binary, "portal"], env=env, stdout=output, stderr=output)


      def name_owned(name):
          return client.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", GLib.Variant("(s)", (name,)), None, 0, 1000, None).unpack()[0]


      def request(title, method="OpenFile", options=None, conn=client):
          opts = dict(options or {})
          opts.setdefault("current_folder", GLib.Variant("ay", bytes(root) + b"\0"))
          reply = call(conn, PUB + "FileChooser", method, GLib.Variant("(ssa{sv})", ("", title, opts)))
          handle = reply.unpack()[0]
          wait(lambda: window(title), "native window: " + title)
          return handle, window(title)


      try:
          wait(lambda: name_owned(PUB + "Desktop"), "native broker name")
          assert not name_owned("org.freedesktop.impl.portal.desktop.gtk")
          handle, title = request("Native portal open")
          ui.focus(title)
          ui.key("ctrl+l")
          ui.type(str(selected))
          ui.key("Return")
          wait(lambda: handle in responses, "open response")
          code, values = responses[handle]
          assert code == 0 and values["uris"] == [selected.as_uri()], responses[handle]
          assert values["writable"] is True
          assert not name_owned("org.freedesktop.impl.portal.desktop.gtk"), "chooser used external GTK backend"
          handle, title = request("Native portal save", "SaveFile", {"current_name": GLib.Variant("s", "ui-save.txt")})
          ui.focus(title)
          ui.key("alt+s")
          wait(lambda: handle in responses, "save response")
          assert responses[handle][0] == 0 and responses[handle][1]["uris"] == [(root / "ui-save.txt").as_uri()], responses[handle]
          assert not (root / "ui-save.txt").exists(), "portal wrote the application's output file"
          handle, title = request("Native portal cancel")
          ui.focus(title)
          ui.key("Escape")
          wait(lambda: handle in responses, "cancel response")
          assert responses[handle][0] == 1
          handle, _ = request("Native portal close")
          rejected(lambda: call(other, PUB + "Request", "Close", path=handle))
          assert window("Native portal close"), "foreign client destroyed dialog"
          call(client, PUB + "Request", "Close", path=handle)
          wait(lambda: not window("Native portal close"), "Close destroys dialog")
          call(client, PUB + "NetworkMonitor", "GetStatus")
          assert handle not in responses, "Close emitted an unwanted Response"
          rejected(lambda: call(client, PUB + "FileChooser", "OpenFile", GLib.Variant("(ssa{sv})", ("", "Invalid chooser", {"current_folder": GLib.Variant("ay", b"/tmp")}))))
          assert not window("Invalid chooser")
          transient = connection()
          handle, _ = request("Native portal disconnected", conn=transient)
          transient.close_sync(None)
          wait(lambda: not window("Native portal disconnected"), "client disconnect destroys dialog")
          print("PASS native chooser D-Bus open/save/cancel, request ownership, Close and client disconnect", flush=True)
          account_title = "Share account information"

          def account_request(conn=client, options=None):
              reply = call(conn, PUB + "Account", "GetUserInformation", GLib.Variant("(sa{sv})", ("", options or {"reason": GLib.Variant("s", "Use your name in the document <not markup>")})))
              account_handle = reply.unpack()[0]
              wait(lambda: window(account_title), "native account window")
              return account_handle, window(account_title)

          handle, title = account_request()
          call(client, PUB + "NetworkMonitor", "GetStatus")
          assert handle not in responses, "account data released before consent"
          ui.focus(title)
          ui.key("Return")
          wait(lambda: handle in responses, "account default response")
          assert responses[handle] == (1, {}), responses[handle]
          handle, title = account_request()
          ui.focus(title)
          ui.key("alt+s")
          wait(lambda: handle in responses, "account consent response")
          code, values = responses[handle]
          assert code == 0, responses[handle]
          assert values["id"] == GLib.get_user_name(), values
          real_name = GLib.get_real_name()
          assert values["name"] == (GLib.get_user_name() if real_name in ("", "Unknown") else real_name), values
          assert values["image"] == (root / "home" / ".face").as_uri(), values
          assert not name_owned("org.freedesktop.impl.portal.desktop.gtk"), "account used external GTK backend"
          (root / "home" / ".face").unlink()
          handle, title = account_request()
          ui.focus(title)
          ui.key("alt+s")
          wait(lambda: handle in responses, "account without picture")
          assert responses[handle][0] == 0 and responses[handle][1]["image"] == ""
          rejected(lambda: account_request(options={"reason": GLib.Variant("b", True)}))
          assert not window(account_title), "invalid account request leaked a window"
          handle, _ = account_request()
          rejected(lambda: call(other, PUB + "Request", "Close", path=handle))
          assert window(account_title), "foreign client destroyed account dialog"
          call(client, PUB + "Request", "Close", path=handle)
          wait(lambda: not window(account_title), "account Close destroys dialog")
          call(client, PUB + "NetworkMonitor", "GetStatus")
          assert handle not in responses, "account Close emitted a Response"
          transient = connection()
          handle, _ = account_request(conn=transient)
          transient.close_sync(None)
          wait(lambda: not window(account_title), "disconnected account dialog")
          print("PASS native account consent/default denial, identity/picture, invalid options, ownership, Close and disconnect", flush=True)

          handle, _ = account_request()
          process.send_signal(signal.SIGTERM)
          wait(lambda: process.poll() is not None, "broker shutdown with dialog")
          assert process.returncode == 0, (root / "broker.log").read_text()
          assert not window(account_title)
          print("PASS shutdown with an open native dialog and checked allocation ownership", flush=True)
      finally:
          if process.poll() is None:
              process.terminate()
              process.wait(timeout=5)
          output.close()
          client.close_sync(None)
          other.close_sync(None)
      PY
    '';
}
