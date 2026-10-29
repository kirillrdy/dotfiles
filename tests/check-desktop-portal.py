"""Exercise the native broker on a private bus with mock GTK/WLR backends."""
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

parser = argparse.ArgumentParser(description=__doc__)
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
        assert values[0] == "sleep:idle", values
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
    elif interface == IMP + "Print":
        descriptors = invocation.get_message().get_unix_fd_list()
        fd = descriptors.get(values[4])
        assert os.read(fd, 100) == b"portal print fixture"
        os.close(fd)
    elif interface == IMP + "ScreenCast":
        handle = values[1]
        if method == "CreateSession":
            sessions[handle] = register("Session", [("Close", "", "")], object_path=handle)
        elif method == "Start":
            results = {"streams": GLib.Variant("a(ua{sv})", [(777, {"size": GLib.Variant("(ii)", (1920, 1080))})])}
    invocation.return_value(GLib.Variant("(ua{sv})", (0, results)))


register("Email", [("ComposeEmail", "ossa{sv}", "ua{sv}")])
register("Screenshot", [("Screenshot", "ossa{sv}", "ua{sv}")])
register("ScreenCast", [("CreateSession", "oosa{sv}", "ua{sv}"), ("SelectSources", "oosa{sv}", "ua{sv}"), ("Start", "oossa{sv}", "ua{sv}")], ["AvailableSourceTypes", "AvailableCursorModes"])
register("Settings", [("Read", "ss", "v"), ("ReadAll", "as", "a{sa{sv}}")])
register("Print", [("Print", "osssha{sv}", "ua{sv}")])
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
    handle, response = request("Email", "ComposeEmail", "(sa{sv})", ("", {"handle_token": GLib.Variant("s", "files")}))
    assert response == (0, {}), response
    assert handle.endswith("/files")
    assert any(entry[2][1] == "org.dotfiles.PortalFixture" for entry in log if entry[0] == IMP + "Email")
    _, response = request("Screenshot", "Screenshot", "(sa{sv})", ("", {}))
    assert response == (0, {"uri": "file:///tmp/screenshot.png"})
    rejected(lambda: request("Email", "ComposeEmail", "(sa{sv})", ("", {"handle_token": GLib.Variant("s", "bad/path")})), "invalid token accepted")
    handle = request("Email", "ComposeEmail", "(sa{sv})", ("", {"hold": GLib.Variant("b", True)}), expect_response=False)
    wait(lambda: handle in held, "backend holds request")
    rejected(lambda: call(other, PUB + "Request", "Close", path=handle), "foreign client closed request")
    call(client, PUB + "Request", "Close", path=handle)
    wait(lambda: handle not in held, "Close propagated to backend")
    assert handle not in responses, "cancelled request emitted Response"
    _, response = request("Email", "ComposeEmail", "(sa{sv})", ("", {"fail": GLib.Variant("b", True)}))
    assert response[0] == 2
    fd = os.memfd_create("portal-print")
    os.write(fd, b"portal print fixture")
    os.lseek(fd, 0, 0)
    fds = Gio.UnixFDList.new()
    index = fds.append(fd)
    os.close(fd)
    _, response = request("Print", "Print", "(ssha{sv})", ("", "Print", index, {}), fds=fds)
    assert response[0] == 0
    print("PASS settings, request responses, owner isolation, cancellation, backend errors and print FD forwarding", flush=True)
    _, implicit = request("ScreenCast", "CreateSession", "(a{sv})", ({},))
    call(client, PUB + "Session", "Close", path=implicit[1]["session_handle"])
    rejected(lambda: request("ScreenCast", "CreateSession", "(a{sv})", ({"session_handle_token": GLib.Variant("u", 1)},)), "non-string session token accepted")
    _, response = request("ScreenCast", "CreateSession", "(a{sv})", ({"session_handle_token": GLib.Variant("s", "cast")},))
    session = response[1]["session_handle"]
    rejected(lambda: call(other, PUB + "Session", "Close", path=session), "foreign client closed session")
    rejected(lambda: call(client, PUB + "ScreenCast", "OpenPipeWireRemote", GLib.Variant("(oa{sv})", (session, {}))), "unstarted session opened remote")
    rejected(lambda: request("ScreenCast", "Start", "(osa{sv})", (session, "", {})), "Start accepted before SelectSources")
    request("ScreenCast", "SelectSources", "(oa{sv})", (session, {"types": GLib.Variant("u", 1)}))
    _, response = request("ScreenCast", "Start", "(osa{sv})", (session, "", {}))
    assert response[1]["streams"][0][0] == 777
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(root / "pipewire-0"))
    listener.listen()
    def serve_socket():
        remote, _ = listener.accept()
        remote.sendall(b"private-pipewire")
        remote.close()
    worker = threading.Thread(target=serve_socket, daemon=True)
    worker.start()
    reply, fds = call(client, PUB + "ScreenCast", "OpenPipeWireRemote", GLib.Variant("(oa{sv})", (session, {})))
    fd = fds.get(reply.unpack()[0])
    assert os.read(fd, 100) == b"private-pipewire"
    os.close(fd)
    listener.close()
    call(client, PUB + "Session", "Close", path=session)
    wait(lambda: session not in sessions, "backend session closed")
    print("PASS screencast sequencing, stream metadata, session ownership and PipeWire FD transfer", flush=True)
    _, response = request("ScreenCast", "CreateSession", "(a{sv})", ({"session_handle_token": GLib.Variant("s", "vanish")},))
    lost_session = response[1]["session_handle"]
    backend.call_sync(BUS, "/org/freedesktop/DBus", BUS, "ReleaseName", GLib.Variant("(s)", (WLR,)), None, 0, 1000, None)
    wait(lambda: lost_session in closed_sessions, "backend loss closes native session")
    rejected(lambda: call(client, PUB + "ScreenCast", "OpenPipeWireRemote", GLib.Variant("(oa{sv})", (lost_session, {}))), "session survived backend loss")
    backend.call_sync(BUS, "/org/freedesktop/DBus", BUS, "RequestName", GLib.Variant("(su)", (WLR, 4)), None, 0, 1000, None)
    print("PASS screencast backend disappearance invalidates sessions", flush=True)

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
    handle = request("Inhibit", "Inhibit", "(sua{sv})", ("", 12, {"reason": GLib.Variant("s", "fixture playback")}), expect_response=False)
    wait(lambda: inhibitor_reads, "logind inhibitor acquired")
    # Process the reply so the broker owns its duplicate before Close.
    for _ in range(20):
        while context.pending(): context.iteration(False)
        time.sleep(0.002)
    read_fd = inhibitor_reads[-1]
    assert not select.select([read_fd], [], [], 0)[0], "inhibitor released too early"
    call(client, PUB + "Request", "Close", path=handle)
    wait(lambda: select.select([read_fd], [], [], 0)[0], "Close releases logind inhibitor")
    assert os.read(read_fd, 1) == b""
    os.close(read_fd)
    print("PASS native logind inhibition and release on Close", flush=True)
    transient = connection()
    transient.signal_subscribe(PUB + "Desktop", PUB + "Request", "Response", None, None, 0, lambda *_: None)
    handle = request("Email", "ComposeEmail", "(sa{sv})", ("", {"hold": GLib.Variant("b", True)}), conn=transient, expect_response=False)
    wait(lambda: handle in held, "transient request pending")
    transient.close_sync(None)
    wait(lambda: handle not in held, "disconnect closes outstanding backend request")
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
    # Shut down while an asynchronous backend request is still pending.
    request("Email", "ComposeEmail", "(sa{sv})", ("", {"hold": GLib.Variant("b", True)}), expect_response=False)
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
