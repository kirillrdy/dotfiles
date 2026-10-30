"""Independent Secret Service consumer. Run under a private dbus-run-session."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--fixture", required=True)
parser.add_argument("--secret-tool", required=True)
parser.add_argument("--compositor")
args = parser.parse_args()
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
root = "/org/freedesktop/secrets"
name = "org.freedesktop.secrets"
prefix = "org.freedesktop.Secret."
password = b"integration-vault-password"
directory = Path(tempfile.mkdtemp(prefix="desktop-secrets-", dir="/tmp")) / "vault"
proc = None
compositor = None
if args.compositor:
    runtime = directory.parent / "runtime"
    runtime.mkdir(mode=0o700)
    config = directory.parent / "labwc"
    config.mkdir()
    (config / "rc.xml").write_text("<labwc_config/>")
    (config / "autostart").write_text("")
    (config / "environment").write_text("LABWC_UPDATE_ACTIVATION_ENV=false\n")
    os.environ.update(XDG_RUNTIME_DIR=str(runtime), GDK_BACKEND="wayland", WAYLAND_DISPLAY="wayland-0",
        WLR_BACKENDS="headless", WLR_RENDERER="pixman", WLR_HEADLESS_OUTPUTS="1",
        LABWC_UPDATE_ACTIVATION_ENV="false", DESKTOP_SECRETS_FIXTURE_PROMPTS="accept")
    compositor = subprocess.Popen([args.compositor, "compositor-only"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(150):
        if (runtime / "wayland-0").exists():
            break
        time.sleep(.02)
    assert (runtime / "wayland-0").exists()

def call(path, interface, method, signature=None, values=(), connection=bus):
    return connection.call_sync(name, path, interface, method,
        GLib.Variant(signature, values) if signature else None, None,
        Gio.DBusCallFlags.NONE, 30000, None).unpack()

def expect_error(suffix, *params, **kwargs):
    try:
        call(*params, **kwargs)
    except GLib.Error as error:
        assert suffix in str(error), (suffix, str(error))
    else:
        raise AssertionError(f"Expected {suffix}")

def prop(path, interface, key):
    return call(path, "org.freedesktop.DBus.Properties", "Get", "(ss)", (interface, key))[0]

def start():
    global proc
    proc = subprocess.Popen([args.fixture, str(directory)], stdout=subprocess.DEVNULL)
    for _ in range(150):
        if proc.poll() is not None:
            raise AssertionError(f"Service exited: {proc.returncode}")
        owned = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "NameHasOwner", GLib.Variant("(s)", (name,)), None, 0, 3000, None).unpack()[0]
        if owned:
            return
        time.sleep(.02)
    raise AssertionError("Service did not start")

def stop():
    global proc
    if proc and proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        assert proc.wait(timeout=10) == 0
    proc = None
    for _ in range(100):
        owned = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "NameHasOwner", GLib.Variant("(s)", (name,)), None, 0, 3000, None).unpack()[0]
        if not owned:
            return
        time.sleep(.01)

try:
    start()
    call(root, "org.dotfiles.Desktop.Secrets", "LoginUnlock", "(ay)", (password,))
    collection = call(root, prefix + "Service", "ReadAlias", "(s)", ("default",))[0]
    assert collection != "/"
    assert not prop(collection, prefix + "Collection", "Locked")
    expect_error("NotSupported", root, prefix + "Service", "OpenSession", "(sv)", ("unknown", GLib.Variant("s", "")))
    expect_error("InvalidArgs", root, prefix + "Service", "OpenSession", "(sv)",
                 ("dh-ietf1024-sha256-aes128-cbc-pkcs7", GLib.Variant("ay", b"\0")))
    _, session = call(root, prefix + "Service", "OpenSession", "(sv)", ("plain", GLib.Variant("s", "")))
    secret = b"binary-secret\0\xff"
    properties = {prefix + "Item.Label": GLib.Variant("s", "Integration credential"),
                  prefix + "Item.Attributes": GLib.Variant("a{ss}", {"application": "test", "account": "alice"})}
    item, prompt = call(collection, prefix + "Collection", "CreateItem", "(a{sv}(oayays)b)",
                       (properties, (session, b"", secret, "application/octet-stream"), True))
    assert prompt == "/"
    result = call(item, prefix + "Item", "GetSecret", "(o)", (session,))[0]
    assert bytes(result[2]) == secret
    assert call(root, prefix + "Service", "SearchItems", "(a{ss})", ({"account": "alice"},)) == ([item], [])
    assert call(collection, prefix + "Collection", "SearchItems", "(a{ss})", ({"account": "alice"},))[0] == [item]
    replacement, _ = call(collection, prefix + "Collection", "CreateItem", "(a{sv}(oayays)b)",
        (properties, (session, b"", b"replacement", "text/plain"), True))
    assert replacement == item
    call(item, "org.freedesktop.DBus.Properties", "Set", "(ssv)",
         (prefix + "Item", "Label", GLib.Variant("s", "Updated label")))
    assert prop(item, prefix + "Item", "Label") == "Updated label"
    peer = Gio.DBusConnection.new_for_address_sync(os.environ["DBUS_SESSION_BUS_ADDRESS"],
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    expect_error("NoSession", item, prefix + "Item", "GetSecret", "(o)", (session,), connection=peer)
    _, peer_session = call(root, prefix + "Service", "OpenSession", "(sv)", ("plain", GLib.Variant("s", "")), connection=peer)
    expect_error("AccessDenied", peer_session, prefix + "Session", "Close")
    peer.close_sync(None)
    time.sleep(.1)
    expect_error("UnknownMethod", peer_session, prefix + "Session", "Close")
    # An independent libsecret binary exercises encrypted DH sessions and AES-CBC.
    tool = [args.secret_tool]
    subprocess.run(tool + ["store", "--label=libsecret test", "desktop-test", "encrypted"],
                   input=b"libsecret-encrypted-value", check=True, timeout=30)
    found = subprocess.check_output(tool + ["lookup", "desktop-test", "encrypted"], timeout=30)
    assert found.rstrip(b"\n") == b"libsecret-encrypted-value"
    subprocess.run(tool + ["clear", "desktop-test", "encrypted"], check=True, timeout=30)
    # A failed atomic write must restore the last committed value in memory.
    before_failure = (directory / "vault.json").read_bytes()
    directory.chmod(0o500)
    try:
        expect_error("Failed", item, prefix + "Item", "SetSecret", "((oayays))",
                     ((session, b"", b"must-not-commit", "text/plain"),))
    finally:
        directory.chmod(0o700)
    assert bytes(call(item, prefix + "Item", "GetSecret", "(o)", (session,))[0][2]) == b"replacement"
    assert (directory / "vault.json").read_bytes() == before_failure
    imported = directory.parent / "imported-vault"
    subprocess.run([args.fixture, "import", str(imported)], check=True, timeout=30)
    imported_data = json.loads((imported / "vault.json").read_text())
    assert len(imported_data["index"]["items"]) == 1
    assert b"replacement" not in (imported / "vault.json").read_bytes()
    call(root, prefix + "Service", "Lock", "(ao)", ([collection],))
    assert prop(item, prefix + "Item", "Locked")
    expect_error("IsLocked", item, prefix + "Item", "GetSecret", "(o)", (session,))
    assert call(root, prefix + "Service", "SearchItems", "(a{ss})", ({"account": "alice"},)) == ([], [item])
    expect_error("Failed", root, "org.dotfiles.Desktop.Secrets", "LoginUnlock", "(ay)", (b"wrong",))
    assert prop(item, prefix + "Item", "Locked")
    _, prompt = call(root, prefix + "Service", "Unlock", "(ao)", ([collection],))
    assert prompt != "/"
    call(prompt, prefix + "Prompt", "Dismiss")
    if args.compositor:
        completed = []
        def on_prompt(connection, sender, path, interface, member, values, data):
            completed.append(values.unpack())
        _, prompt = call(root, prefix + "Service", "Unlock", "(ao)", ([item],))
        subscription = bus.signal_subscribe(name, prefix + "Prompt", "Completed", prompt, None, 0, on_prompt, None)
        call(prompt, prefix + "Prompt", "Prompt", "(s)", ("",))
        deadline = time.monotonic() + 10
        while not completed and time.monotonic() < deadline:
            GLib.MainContext.default().iteration(False)
            time.sleep(.01)
        bus.signal_unsubscribe(subscription)
        assert completed and not completed[0][0] and completed[0][1] == [item], completed
        assert not prop(item, prefix + "Item", "Locked")
        call(root, prefix + "Service", "Lock", "(ao)", ([collection],))
        assert subprocess.check_output(tool + ["lookup", "account", "alice"], timeout=30).rstrip(b"\n") == b"replacement"
    call(root, "org.dotfiles.Desktop.Secrets", "LoginUnlock", "(ay)", (password,))
    call(root, "org.dotfiles.Desktop.Secrets", "SetScreenLocked", "(b)", (True,))
    expect_error("IsLocked", root, "org.dotfiles.Desktop.Secrets", "LoginUnlock", "(ay)", (password,))
    call(root, "org.dotfiles.Desktop.Secrets", "SetScreenLocked", "(b)", (False,))
    call(root, "org.dotfiles.Desktop.Secrets", "LoginUnlock", "(ay)", (password,))
    raw = (directory / "vault.json").read_bytes()
    assert b"replacement" not in raw and b"libsecret-encrypted-value" not in raw
    assert (directory / "vault.json").stat().st_mode & 0o077 == 0
    assert directory.stat().st_mode & 0o077 == 0
    stop()
    start()
    assert prop(item, prefix + "Item", "Locked")
    call(root, "org.dotfiles.Desktop.Secrets", "LoginUnlock", "(ay)", (password,))
    _, session = call(root, prefix + "Service", "OpenSession", "(sv)", ("plain", GLib.Variant("s", "")))
    assert bytes(call(item, prefix + "Item", "GetSecret", "(o)", (session,))[0][2]) == b"replacement"
    call(item, prefix + "Item", "Delete")
    assert call(root, prefix + "Service", "SearchItems", "(a{ss})", ({"account": "alice"},)) == ([], [])
    extra, _ = call(root, prefix + "Service", "CreateCollection", "(a{sv}s)",
        ({prefix + "Collection.Label": GLib.Variant("s", "Extra")}, "extra"))
    call(root, prefix + "Service", "SetAlias", "(so)", ("extra_alias", extra))
    assert call(root, prefix + "Service", "ReadAlias", "(s)", ("extra_alias",))[0] == extra
    call(extra, prefix + "Collection", "Delete")
    assert call(root, prefix + "Service", "ReadAlias", "(s)", ("extra_alias",))[0] == "/"
    stop()
    original_directory = directory
    directory = imported
    start()
    call(root, "org.dotfiles.Desktop.Secrets", "LoginUnlock", "(ay)", (password,))
    assert subprocess.check_output(tool + ["lookup", "account", "alice"], timeout=30).rstrip(b"\n") == b"replacement"
    stop()
    directory = original_directory
    damaged = json.loads((directory / "vault.json").read_text())
    damaged["index"]["collections"][0]["label"] = "tampered"
    (directory / "vault.json").write_text(json.dumps(damaged))
    start()
    expect_error("Failed", root, "org.dotfiles.Desktop.Secrets", "LoginUnlock", "(ay)", (password,))
    print("Secret Service: protocol, libsecret DH, persistence, locking, ownership, and tampering checks passed")
finally:
    stop()
    if compositor:
        compositor.terminate()
        compositor.wait(timeout=10)
