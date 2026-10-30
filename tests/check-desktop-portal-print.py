"""Exercise native print requests on a private bus/display using only files."""
import argparse
import os
from pathlib import Path
import signal
import subprocess as sp
import tempfile
import time
from urllib.parse import unquote, urlsplit

import gi
from wayland_ui import WaylandUI

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True)
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="desktop-portal-print-", dir="/tmp"))
print(f"Artifacts: {root}", flush=True)
for directory in ("home", "config", "cache", "data"):
    (root / directory).mkdir()
env = dict(os.environ, HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"), XDG_CACHE_HOME=str(root / "cache"), XDG_DATA_HOME=str(root / "data"), GTK_PRINT_BACKENDS="file", GTK_USE_PORTAL="0", GIO_USE_VFS="local", NO_AT_BRIDGE="1", GSETTINGS_BACKEND="memory", G_DEBUG="fatal-criticals", LC_ALL="C")
PUB = "org.freedesktop.portal."
P = "/org/freedesktop/portal/desktop"
context = GLib.MainContext.default()
responses = {}


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
    conn = Gio.DBusConnection.new_for_address_sync(os.environ["DBUS_SESSION_BUS_ADDRESS"], Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    conn.signal_subscribe(PUB + "Desktop", PUB + "Request", "Response", None, None, 0, lambda conn, sender, path, interface, signal, params: responses.__setitem__(path, params.unpack()))
    return conn


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


ui = WaylandUI(env)
window = ui.window


client = connection()
other = connection()
output = (root / "broker.log").open("w")
process = sp.Popen([args.binary, "portal"], env=env, stdout=output, stderr=output)


def owned(name):
    return client.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", GLib.Variant("(s)", (name,)), None, 0, 1000, None).unpack()[0]


def prepare(title, target=None, conn=client, options=None, settings=None, page=None):
    hints = {"printer": GLib.Variant("s", "Print to File"), "output-uri": GLib.Variant("s", (target or root / "unused.pdf").as_uri()), "output-file-format": GLib.Variant("s", "pdf")}
    hints.update(settings or {})
    opts = {"accept_label": GLib.Variant("s", "_Go"), "supported_output_file_formats": GLib.Variant("as", ["pdf"])}
    opts.update(options or {})
    handle = call(conn, PUB + "Print", "PreparePrint", GLib.Variant("(ssa{sv}a{sv}a{sv})", ("", title, hints, page or {}, opts))).unpack()[0]
    wait(lambda: window(title), "native print window: " + title)
    return handle, window(title)


def accept(handle, title):
    ui.focus(title)
    until = time.monotonic() + 10
    while handle not in responses:
        while context.pending():
            context.iteration(False)
        assert time.monotonic() < until, "print consent response"
        ui.key("alt+g")
        time.sleep(0.05)
    code, values = responses[handle]
    assert code == 0, responses[handle]
    return values


def print_file(title, descriptors=None, index=0, options=None, conn=client):
    return call(conn, PUB + "Print", "Print", GLib.Variant("(ssha{sv})", ("", title, index, options or {})), fds=descriptors).unpack()[0]


try:
    wait(lambda: owned(PUB + "Desktop"), "broker starts")
    version = call(client, "org.freedesktop.DBus.Properties", "Get", GLib.Variant("(ss)", (PUB + "Print", "version"))).unpack()[0]
    assert version == 4, version
    for conn in (client, other):
        call(conn, "org.freedesktop.host.portal.Registry", "Register", GLib.Variant("(sa{sv})", ("org.dotfiles.PrintFixture", {})))
    target = root / "文書 output.pdf"
    handle, title = prepare("Native print setup", target, page={"Name": GLib.Variant("s", "custom"), "DisplayName": GLib.Variant("s", "Fixture paper"), "Width": GLib.Variant("d", 210), "Height": GLib.Variant("d", 297), "Orientation": GLib.Variant("s", "landscape")}, options={"has_current_page": GLib.Variant("b", True), "has_selected_pages": GLib.Variant("b", True)})
    result = accept(handle, title)
    token = result["token"]
    assert token > 0 and result["page-setup"]["Orientation"] == "landscape", result
    assert Path(unquote(urlsplit(result["settings"]["output-uri"]).path)) == target, result
    assert not target.exists(), "PreparePrint submitted a job"
    document = b"%PDF-1.4\n% native FD transport fixture\n\x00\xff\n%%EOF\n"
    fd = os.memfd_create("portal-print")
    os.write(fd, document)
    descriptors = Gio.UnixFDList.new()
    descriptors.append(fd)
    os.close(fd)
    opts = {"token": GLib.Variant("u", token)}
    rejected(lambda: print_file("Foreign token", descriptors, options=opts, conn=other))
    rejected(lambda: print_file("Missing descriptor", options=opts))
    for index in (-1, 1):
        rejected(lambda: print_file("Invalid descriptor", descriptors, index=index, options=opts))
    directory = os.open(root, os.O_RDONLY)
    bad_fds = Gio.UnixFDList.new()
    bad_fds.append(directory)
    os.close(directory)
    rejected(lambda: print_file("Directory descriptor", bad_fds, options=opts))
    handle = print_file("Native prepared job", descriptors, options=opts)
    wait(lambda: handle in responses, "print completion")
    assert responses[handle] == (0, {}), responses[handle]
    assert target.read_bytes() == document
    assert not window("Native prepared job"), "prepared job reopened the print dialog"
    rejected(lambda: print_file("Reused token", descriptors, options=opts))
    assert not owned("org.freedesktop.impl.portal.desktop.gtk"), "printing used GTK portal backend"
    for opts in ({"modal": GLib.Variant("s", "yes")}, {"supported_output_file_formats": GLib.Variant("as", [])}, {"supported_output_file_formats": GLib.Variant("as", ["jpeg"])}):
        rejected(lambda: prepare("Invalid print options", options=opts))
    rejected(lambda: prepare("Invalid settings", settings={"n-copies": GLib.Variant("u", 2)}))
    rejected(lambda: prepare("Invalid page", page={"Width": GLib.Variant("d", -1)}))
    print("PASS native print preparation, settings, caller-owned single-use tokens, FD output and invalid requests", flush=True)
    handle = print_file("Cancel direct printing", descriptors)
    wait(lambda: window("Cancel direct printing"), "direct print window")
    ui.focus("Cancel direct printing")
    ui.key("Escape")
    wait(lambda: handle in responses, "direct print cancellation")
    assert responses[handle] == (1, {}), responses[handle]
    handle, _ = prepare("Close native printing")
    rejected(lambda: call(other, PUB + "Request", "Close", path=handle))
    assert window("Close native printing")
    call(client, PUB + "Request", "Close", path=handle)
    wait(lambda: not window("Close native printing"), "Close destroys print dialog")
    call(client, PUB + "NetworkMonitor", "GetStatus")
    assert handle not in responses, "Close emitted a Response"
    transient = connection()
    prepare("Disconnected native printing", conn=transient)
    transient.close_sync(None)
    wait(lambda: not window("Disconnected native printing"), "disconnect destroys print dialog")
    handle, title = prepare("Prepared at shutdown", root / "never-printed.pdf")
    accept(handle, title)
    prepare("Shutdown native printing")
    process.send_signal(signal.SIGTERM)
    wait(lambda: process.poll() is not None, "broker shutdown")
    assert process.returncode == 0, (root / "broker.log").read_text()
    assert not window("Shutdown native printing")
    assert not (root / "never-printed.pdf").exists()
    print("PASS native print cancellation, ownership, Close, disconnect and shutdown with prepared settings and checked allocation ownership", flush=True)
finally:
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=5)
    output.close()
    client.close_sync(None)
    other.close_sync(None)
