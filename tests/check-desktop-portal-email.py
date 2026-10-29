"""Check native email launches with isolated mail handlers; no mail is sent."""
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

parser = argparse.ArgumentParser(description=__doc__)
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
    # Empty XDG search paths prevent fallback to a real installed mail client.
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

    # A D-Bus mail handler can keep a launch pending for lifecycle checks.
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
