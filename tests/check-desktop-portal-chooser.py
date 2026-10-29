"""Exercise native file and account dialogs on a private X server."""
import argparse
import os
from pathlib import Path
import re
import signal
import subprocess as sp
import tempfile
import time
import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True)
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="desktop-portal-chooser-", dir="/tmp"))
print(f"Artifacts: {root}", flush=True)
for name in ("config", "cache", "data", "home"):
    (root / name).mkdir()
selected = root / "selected file.txt"
selected.write_text("native chooser fixture\n")
(root / "home" / ".face").write_text("account picture fixture\n")
env = dict(os.environ, HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"), XDG_CACHE_HOME=str(root / "cache"), XDG_DATA_HOME=str(root / "data"), XDG_RUNTIME_DIR=str(root), GTK_USE_PORTAL="0", GIO_USE_VFS="local", NO_AT_BRIDGE="1", GSETTINGS_BACKEND="memory", G_DEBUG="fatal-criticals")
PUB = "org.freedesktop.portal."
P = "/org/freedesktop/portal/desktop"
context = GLib.MainContext.default()


def wait(check, description, timeout=12):
    until = time.monotonic() + timeout
    while not check():
        while context.pending():
            context.iteration(False)
        assert time.monotonic() < until, description
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


def xdo(*command, check=True):
    return sp.run(["xdotool", *map(str, command)], env=env, check=check, capture_output=True, text=True, timeout=5)


def window(title):
    result = xdo("search", "--onlyvisible", "--name", "^" + re.escape(title) + "$", check=False)
    return result.stdout.splitlines()[0] if result.returncode == 0 and result.stdout else None


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
    handle, xid = request("Native portal open")
    xdo("windowfocus", "--sync", xid)
    xdo("key", "--clearmodifiers", "ctrl+l")
    xdo("type", "--clearmodifiers", "--delay", 1, str(selected))
    xdo("key", "--clearmodifiers", "Return")
    wait(lambda: handle in responses, "open response")
    code, values = responses[handle]
    assert code == 0 and values["uris"] == [selected.as_uri()], responses[handle]
    assert values["writable"] is True
    assert not name_owned("org.freedesktop.impl.portal.desktop.gtk"), "chooser used external GTK backend"
    handle, xid = request("Native portal save", "SaveFile", {"current_name": GLib.Variant("s", "ui-save.txt")})
    xdo("windowfocus", "--sync", xid)
    xdo("key", "--clearmodifiers", "alt+s")
    wait(lambda: handle in responses, "save response")
    assert responses[handle][0] == 0 and responses[handle][1]["uris"] == [(root / "ui-save.txt").as_uri()], responses[handle]
    assert not (root / "ui-save.txt").exists(), "portal wrote the application's output file"
    handle, xid = request("Native portal cancel")
    xdo("windowfocus", "--sync", xid)
    xdo("key", "--clearmodifiers", "Escape")
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

    handle, xid = account_request()
    call(client, PUB + "NetworkMonitor", "GetStatus")
    assert handle not in responses, "account data released before consent"
    xdo("windowfocus", "--sync", xid)
    xdo("key", "--clearmodifiers", "Return")
    wait(lambda: handle in responses, "account default response")
    assert responses[handle] == (1, {}), responses[handle]
    handle, xid = account_request()
    xdo("windowfocus", "--sync", xid)
    xdo("key", "--clearmodifiers", "alt+s")
    wait(lambda: handle in responses, "account consent response")
    code, values = responses[handle]
    assert code == 0, responses[handle]
    assert values["id"] == GLib.get_user_name(), values
    real_name = GLib.get_real_name()
    assert values["name"] == (GLib.get_user_name() if real_name in ("", "Unknown") else real_name), values
    assert values["image"] == (root / "home" / ".face").as_uri(), values
    assert not name_owned("org.freedesktop.impl.portal.desktop.gtk"), "account used external GTK backend"
    (root / "home" / ".face").unlink()
    handle, xid = account_request()
    xdo("windowfocus", "--sync", xid)
    xdo("key", "--clearmodifiers", "alt+s")
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
