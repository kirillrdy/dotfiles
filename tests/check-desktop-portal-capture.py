"""Exercise native capture and live PipeWire video in a private headless Wayland session.

Run under dbus-run-session; no WLR portal backend is started.
"""
import argparse
import json
import os
from pathlib import Path
import select
import signal
import socket
import stat
import subprocess as sp
import tempfile
import time
from urllib.parse import unquote, urlparse
import gi

gi.require_version("Gio", "2.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gio, GLib, GdkPixbuf
from audio_server import PW_CONFIG, WP_CONFIG

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True)
parser.add_argument("--video-consumer", required=True)
parser.add_argument("--pointer", required=True)
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="desktop-portal-capture-", dir="/tmp"))
print(f"Artifacts: {root}", flush=True)
for directory in ("runtime", "config/labwc", "cache", "data", "home", "config/wireplumber/wireplumber.conf.d"):
    (root / directory).mkdir(parents=True, mode=0o700, exist_ok=True)
(root / "config/labwc/rc.xml").write_text("<labwc_config><keyboard><default/></keyboard></labwc_config>")
(root / "config/labwc/autostart").write_text("")
(root / "config/labwc/environment").write_text("LABWC_UPDATE_ACTIVATION_ENV=false\n")
(root / "config/wireplumber/wireplumber.conf.d/90-fixture.conf").write_text(WP_CONFIG)
(root / "pipewire.conf").write_text(PW_CONFIG.replace("audio.convert.*", "video.convert.* = videoconvert/libspa-videoconvert audio.convert.*"))
env = dict(os.environ, HOME=str(root / "home"), XDG_RUNTIME_DIR=str(root / "runtime"),
           XDG_CONFIG_HOME=str(root / "config"), XDG_CACHE_HOME=str(root / "cache"), XDG_DATA_HOME=str(root / "data"),
           XDG_STATE_HOME=str(root / "state"), WLR_BACKENDS="headless", WLR_RENDERER="pixman", WLR_HEADLESS_OUTPUTS="1",
           LABWC_UPDATE_ACTIVATION_ENV="false", NO_AT_BRIDGE="1", GTK_USE_PORTAL="0", GIO_USE_VFS="local",
           GSETTINGS_BACKEND="memory", G_DEBUG="fatal-criticals", GDK_BACKEND="wayland", DESKTOP_PORTAL_FIXTURE_CAPTURE="1",
           PIPEWIRE_REMOTE="pipewire-0")
for key in ("DISPLAY", "WAYLAND_DISPLAY", "LABWC_PID", "PIPEWIRE_RUNTIME_DIR", "PIPEWIRE_CONFIG_DIR", "WIREPLUMBER_CONFIG_DIR", "WIREPLUMBER_DATA_DIR"):
    env.pop(key, None)
P = "/org/freedesktop/portal/desktop"
PUB = "org.freedesktop.portal."
context = GLib.MainContext.default()
processes = []


def start(command, name, **kwargs):
    with (root / name).open("w") as log:
        process = sp.Popen(command, env=env, stderr=log, **kwargs)
    processes.append(process)
    return process


def wait(check, description, timeout=12):
    until = time.monotonic() + timeout
    while not check():
        while context.pending():
            context.iteration(False)
        assert time.monotonic() < until, description + "\n" + (root / "broker.log").read_text() if (root / "broker.log").exists() else description
        time.sleep(.01)


def connection():
    return Gio.DBusConnection.new_for_address_sync(os.environ["DBUS_SESSION_BUS_ADDRESS"], Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)


def call(conn, interface, method, params=None, path=P):
    results = []
    def finished(source, task):
        try:
            results.append(source.call_with_unix_fd_list_finish(task))
        except GLib.Error as error:
            results.append(error)
    conn.call_with_unix_fd_list(PUB + "Desktop", path, interface, method, params, None, 0, 5000, None, None, finished)
    wait(lambda: results, method + " reply")
    if isinstance(results[0], GLib.Error):
        raise results[0]
    return results[0]


def reject(function):
    try:
        function()
    except GLib.Error:
        return
    raise AssertionError("foreign owner accepted")


responses, closed, foreign = {}, [], []
client, other = connection(), connection()
client.signal_subscribe(PUB + "Desktop", PUB + "Request", "Response", None, None, 0, lambda conn, sender, path, iface, name, params: responses.__setitem__(path, params.unpack()))
client.signal_subscribe(PUB + "Desktop", PUB + "Session", "Closed", None, None, 0, lambda conn, sender, path, *rest: closed.append(path))
other.signal_subscribe(PUB + "Desktop", PUB + "Request", "Response", None, None, 0, lambda *event: foreign.append(event))


def request(interface, method, signature, values, conn=client):
    reply, _ = call(conn, PUB + interface, method, GLib.Variant(signature, values))
    return reply.unpack()[0]


def response(handle):
    wait(lambda: handle in responses, "Response " + handle)
    return responses.pop(handle)


def reply(title, accepted=True, area=False):
    def respond():
        result, _ = call(client, "org.dotfiles.CaptureFixture", "Reply", GLib.Variant("(sbb)", (title, accepted, area)), path="/org/dotfiles/CaptureFixture")
        return result.unpack()[0]
    wait(respond, "dialog " + title)


def color(red, green, blue):
    call(client, "org.dotfiles.CaptureFixture", "Color", GLib.Variant("(ddd)", (red, green, blue)), path="/org/dotfiles/CaptureFixture")
    time.sleep(.2)


def image(results):
    assert results[0] == 0, results
    path = Path(unquote(urlparse(results[1]["uri"]).path))
    assert path.is_relative_to(root / "runtime")
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    pixels = GdkPixbuf.Pixbuf.new_from_file(str(path))
    return path, pixels


def move(*commands):
    for command in commands:
        pointer.stdin.write(command + "\n")
        pointer.stdin.flush()
        assert select.select([pointer.stdout], [], [], 5)[0], "pointer acknowledgement"
        assert pointer.stdout.readline().strip() == "ok"
        time.sleep(.08)


def selected_session(conn=client):
    handle = request("ScreenCast", "CreateSession", "(a{sv})", ({},), conn=conn)
    session = response(handle)[1]["session_handle"]
    handle = request("ScreenCast", "SelectSources", "(oa{sv})", (session, {}), conn=conn)
    assert response(handle) == (0, {})
    return session


def node_exists(node):
    result = sp.run(["pw-dump"], env=env, check=True, capture_output=True, text=True, timeout=5)
    return any(item.get("id") == node for item in json.loads(result.stdout))


try:
    compositor = start(["labwc", "-C", str(root / "config/labwc")], "labwc.log", stdout=sp.DEVNULL)
    wait(lambda: list((root / "runtime").glob("wayland-*.lock")), "private compositor")
    env["WAYLAND_DISPLAY"] = next((root / "runtime").glob("wayland-*.lock")).stem
    pipewire = start(["pipewire", "-c", str(root / "pipewire.conf")], "pipewire.log", stdout=sp.DEVNULL)
    wait(lambda: (root / "runtime/pipewire-0").exists(), "private PipeWire")
    wireplumber = start(["wireplumber"], "wireplumber.log", stdout=sp.DEVNULL)
    broker = start([args.binary], "broker.log", stdout=sp.DEVNULL)
    def owned():
        return client.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", GLib.Variant("(s)", (PUB + "Desktop",)), None, 0, 1000, None).unpack()[0]
    wait(owned, "native broker")
    pointer = start([args.pointer], "pointer.log", stdin=sp.PIPE, stdout=sp.PIPE, text=True)
    assert select.select([pointer.stdout], [], [], 5)[0]
    assert pointer.stdout.readline().strip() == "ready"
    color(1., 0., 0.)
    handle = request("Screenshot", "Screenshot", "(sa{sv})", ("", {}))
    assert handle not in responses, "screenshot shared before consent"
    reject(lambda: call(other, PUB + "Request", "Close", path=handle))
    reply("Share a screenshot")
    path, pixels = image(response(handle))
    width, height = pixels.get_width(), pixels.get_height()
    offset = height // 2 * pixels.get_rowstride() + width // 2 * pixels.get_n_channels()
    assert pixels.get_pixels()[offset:offset + 3] == bytes((255, 0, 0)), "screenshot has wrong pixels"
    handle = request("Screenshot", "Screenshot", "(sa{sv})", ("", {}))
    reply("Share a screenshot")
    second, _ = image(response(handle))
    assert path != second, "screenshot overwritten"
    handle = request("Screenshot", "Screenshot", "(sa{sv})", ("", {}))
    reply("Share a screenshot", False)
    assert response(handle) == (1, {})
    handle = request("Screenshot", "Screenshot", "(sa{sv})", ("", {}))
    call(client, PUB + "Request", "Close", path=handle)
    time.sleep(.1)
    assert handle not in responses
    count = len(list((root / "runtime").glob("desktop-screenshot-*")))
    handle = request("Screenshot", "Screenshot", "(sa{sv})", ("", {}))
    reply("Share a screenshot")
    call(client, PUB + "Request", "Close", path=handle)
    time.sleep(.25)
    assert handle not in responses
    assert len(list((root / "runtime").glob("desktop-screenshot-*"))) == count, "cancelled capture wrote a file"
    print("PASS native screenshot pixels, private unique files, consent and owner cancellation", flush=True)

    handle = request("Screenshot", "PickColor", "(sa{sv})", ("", {}))
    reply("Pick a color")
    time.sleep(.3)
    move("move 100 100", "button 1", "button 0")
    picked = response(handle)
    assert picked == (0, {"color": (1., 0., 0.)}), picked
    handle = request("Screenshot", "Screenshot", "(sa{sv})", ("", {"interactive": GLib.Variant("b", True)}))
    reply("Share a screenshot", area=True)
    time.sleep(.3)
    move("move 100 100", "button 1", "move 400 300", "button 0")
    _, region = image(response(handle))
    assert abs(region.get_width() - width * 300 / 1728) <= 2
    assert abs(region.get_height() - height * 200 / 1080) <= 2
    print("PASS native color picking and area capture", flush=True)

    handle = request("ScreenCast", "CreateSession", "(a{sv})", ({},))
    session = response(handle)[1]["session_handle"]
    handle = request("ScreenCast", "SelectSources", "(oa{sv})", (session, {"types": GLib.Variant("u", 1), "cursor_mode": GLib.Variant("u", 1)}))
    assert response(handle) == (0, {})
    handle = request("ScreenCast", "Start", "(osa{sv})", (session, "", {}))
    assert handle not in responses, "screen shared before consent"
    reply("Share your screen")
    result = response(handle)
    assert result[0] == 0, result
    node, properties = result[1]["streams"][0]
    assert properties["source_type"] == 1
    reject(lambda: call(other, PUB + "ScreenCast", "OpenPipeWireRemote", GLib.Variant("(oa{sv})", (session, {}))))
    remote, fds = call(client, PUB + "ScreenCast", "OpenPipeWireRemote", GLib.Variant("(oa{sv})", (session, {})))
    fd = fds.get(remote.unpack()[0])
    with socket.socket(fileno=fd) as sock:
        assert sock.getpeername() == str(root / "runtime/pipewire-0")
    consumer = start([args.video_consumer, str(node), str(width), str(height)], "consumer.log", stdout=sp.PIPE, text=True)
    assert select.select([consumer.stdout], [], [], 12)[0], "no video frame\n" + (root / "broker.log").read_text() + (root / "consumer.log").read_text()
    assert consumer.stdout.readline().strip() == "red"
    color(0., 0., 1.)
    assert select.select([consumer.stdout], [], [], 12)[0], "video failed to update"
    assert consumer.stdout.readline().strip() == "blue"
    assert consumer.wait(timeout=5) == 0, (root / "consumer.log").read_text()
    call(client, PUB + "Session", "Close", path=session)
    wait(lambda: session in closed, "session Close")
    dump = sp.run(["pw-dump"], env=env, check=True, capture_output=True, text=True, timeout=5)
    assert not any(item.get("id") == node for item in json.loads(dump.stdout)), "video node leaked"
    print("PASS live PipeWire red/blue frames, stream metadata, remote FD ownership and node cleanup", flush=True)

    session = selected_session()
    handle = request("ScreenCast", "Start", "(osa{sv})", (session, "", {}))
    reply("Share your screen", False)
    assert response(handle) == (1, {})
    wait(lambda: session in closed, "cancelled Start closes session")
    session = selected_session()
    handle = request("ScreenCast", "Start", "(osa{sv})", (session, "", {}))
    reply("Share your screen")
    call(client, PUB + "Request", "Close", path=handle)
    wait(lambda: session in closed, "Close cancels pending stream initialization")
    assert handle not in responses

    transient = connection()
    subscription = transient.signal_subscribe(PUB + "Desktop", PUB + "Request", "Response", None, None, 0, lambda conn, sender, path, iface, name, params: responses.__setitem__(path, params.unpack()))
    session = selected_session(transient)
    handle = request("ScreenCast", "Start", "(osa{sv})", (session, "", {}), conn=transient)
    reply("Share your screen")
    live = response(handle)
    assert live[0] == 0, live
    transient_node = live[1]["streams"][0][0]
    transient.signal_unsubscribe(subscription)
    transient.close_sync(None)
    wait(lambda: not node_exists(transient_node), "disconnected client releases video node")
    assert session not in closed, "Closed leaked to another owner"

    session = selected_session()
    handle = request("ScreenCast", "Start", "(osa{sv})", (session, "", {}))
    reply("Share your screen")
    assert response(handle)[0] == 0
    pipewire.terminate()
    pipewire.wait(timeout=5)
    wait(lambda: session in closed, "PipeWire failure closes active session")
    assert broker.poll() is None, (root / "broker.log").read_text()
    print("PASS cancelled Start, pending stream Close, active client disconnect and PipeWire failure", flush=True)

    # Client disappearance closes pending native selectors.
    transient = connection()
    request("Screenshot", "Screenshot", "(sa{sv})", ("", {}), conn=transient)
    transient.close_sync(None)
    time.sleep(.2)
    # Shutdown while another native selector is pending, with checked allocation ownership.
    request("Screenshot", "Screenshot", "(sa{sv})", ("", {}))
    broker.send_signal(signal.SIGTERM)
    wait(lambda: broker.poll() is not None, "broker shutdown")
    assert broker.returncode == 0, (root / "broker.log").read_text()
    assert not foreign, "responses leaked to foreign clients"
    print("PASS disconnect cleanup and clean shutdown with a pending capture request", flush=True)
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except sp.TimeoutExpired:
                process.kill()
                process.wait()
    client.close_sync(None)
    other.close_sync(None)
