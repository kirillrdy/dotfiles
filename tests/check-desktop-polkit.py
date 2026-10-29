"""Exercise the Zig agent with a private authority and an unprivileged socket."""
import argparse
import os
from pathlib import Path
import pwd
import queue
import socket
import subprocess
import tempfile
import threading
import time

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True)
args = parser.parse_args()
NAME = "org.freedesktop.PolicyKit1"
AUTH = NAME + ".Authority"
AGENT = NAME + ".AuthenticationAgent"
PATH = "/org/freedesktop/PolicyKit1/Authority"
BUS = "org.freedesktop.DBus"
context = GLib.MainContext.default()
root = Path(tempfile.mkdtemp(prefix="polkit-agent-check-"))


def pump(seconds=0):
    until = time.monotonic() + seconds
    while True:
        while context.pending():
            context.iteration(False)
        if time.monotonic() >= until:
            return
        time.sleep(.002)


def wait(check, description, timeout=8):
    until = time.monotonic() + timeout
    while not check():
        pump(.005)
        assert time.monotonic() < until, description


def connection():
    return Gio.DBusConnection.new_for_address_sync(
        os.environ["DBUS_SESSION_BUS_ADDRESS"],
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
        None, None)


authority = connection()
outsider = connection()
registered = []
unregistered = []
xml = f"""<node><interface name='{AUTH}'>
<method name='RegisterAuthenticationAgent'><arg type='(sa{{sv}})' direction='in'/><arg type='s' direction='in'/><arg type='o' direction='in'/></method>
<method name='UnregisterAuthenticationAgent'><arg type='(sa{{sv}})' direction='in'/><arg type='o' direction='in'/></method>
</interface></node>"""


def method(conn, sender, path, interface, name, parameters, invocation):
    if name == "RegisterAuthenticationAgent":
        registered.append((sender, parameters.unpack()))
    else:
        unregistered.append(sender)
    invocation.return_value(None)


node = Gio.DBusNodeInfo.new_for_xml(xml)
authority.register_object(PATH, node.interfaces[0], method, None, None)


def own(acquire):
    authority.call_sync(BUS, "/org/freedesktop/DBus", BUS,
                        "RequestName" if acquire else "ReleaseName",
                        GLib.Variant("(su)", (NAME, 4)) if acquire else GLib.Variant("(s)", (NAME,)),
                        None, 0, 1000, None)


def call(name, parameters, conn=authority):
    result = []
    def done(source, task):
        try:
            result.append(source.call_finish(task))
        except GLib.Error as error:
            result.append(error)
    sender, (_, _, path) = registered[-1]
    conn.call(sender, path, AGENT, name, parameters, None, 0, 15000, None, done)
    return result


def begin(cookie, conn=authority, identities=None):
    if identities is None:
        identities = [("unix-user", {"uid": GLib.Variant("u", os.getuid())})]
    return call("BeginAuthentication", GLib.Variant("(sssa{ss}sa(sa{sv}))", (
        "org.dotfiles.test", "Private test: 東京 <&>", "", {}, cookie, identities)), conn)


def finished(result, error=None):
    wait(lambda: result, "agent reply")
    if error:
        assert isinstance(result[0], GLib.Error), result
        assert error in str(result[0]), result
    else:
        assert not isinstance(result[0], GLib.Error), result


plans = queue.Queue()
events = queue.Queue()
failures = queue.Queue()
listener = socket.socket(socket.AF_UNIX)
endpoint = str(root / "helper.socket")
listener.bind(endpoint)
listener.listen(16)


def helpers():
    while True:
        client, _ = listener.accept()
        try:
            client.settimeout(8)
            stream = client.makefile("rb")
            username = stream.readline().decode().rstrip("\n")
            cookie = stream.readline().decode().rstrip("\n")
            if not username and not cookie:
                events.put("peer-rejected")
                stream.close()
                continue
            assert username == pwd.getpwuid(os.getuid()).pw_name
            expected_cookie, steps = plans.get(timeout=8)
            assert cookie == expected_cookie, (cookie, expected_cookie)
            for payload, answer in steps:
                # Split commands across reads, including escaped Unicode text.
                client.sendall(payload[:7])
                time.sleep(.005)
                client.sendall(payload[7:])
                if answer is not None:
                    events.put(cookie)
                    received = stream.readline()
                    if answer == "closed":
                        assert received == b"", received
                    else:
                        assert received == answer + b"\n", "incorrect helper response"
            stream.close()
        except Exception as error:
            failures.put(error)
        finally:
            client.close()


threading.Thread(target=helpers, daemon=True).start()


def plan(cookie, *steps):
    plans.put((cookie, steps))


def prompt(cookie, answer=b"fake-response", echo=False):
    command = b"PAM_PROMPT_ECHO_ON " if echo else b"PAM_PROMPT_ECHO_OFF "
    return (command + b"Password\\t\\346\\235\\261\\344\\272\\254 <&>:\n", answer)


def answer(cookie, value="fake-response"):
    wait(lambda: not events.empty(), "helper prompt")
    assert events.get_nowait() == cookie
    pump(.15)
    windows = subprocess.check_output(["xdotool", "search", "--onlyvisible", "--name", "^Authentication Required$"]).split()
    assert len(windows) == 1, windows
    window = windows[0].decode()
    subprocess.run(["xdotool", "windowfocus", "--sync", window], check=True)
    subprocess.run(["xdotool", "type", "--clearmodifiers", "--", value], check=True)
    subprocess.run(["xdotool", "key", "--clearmodifiers", "Return"], check=True)


process = None
logs = open(root / "agent.log", "w+")
env = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=os.environ["DBUS_SESSION_BUS_ADDRESS"],
           G_DEBUG="fatal-criticals", NO_AT_BRIDGE="1", GTK_USE_PORTAL="0",
           GIO_USE_VFS="local", GSETTINGS_BACKEND="memory")
env.pop("XDG_SESSION_ID", None)


def start(peer=None):
    global process
    count = len(registered)
    command = [args.binary, endpoint] + ([] if peer is None else [str(peer)])
    process = subprocess.Popen(command, env=env, stdout=logs, stderr=logs)
    wait(lambda: len(registered) > count or process.poll() is not None, "agent registration")
    assert process.poll() is None, "agent startup failed"
    subject, locale, _ = registered[-1][1]
    assert subject[0] == "unix-process", subject
    assert subject[1]["pid"] == process.pid
    assert subject[1]["uid"] == os.getuid()
    stat = Path(f"/proc/{process.pid}/stat").read_text().rsplit(")", 1)[1].split()
    assert subject[1]["start-time"] == int(stat[19])
    assert locale == env.get("LANG", "C")


def stop():
    process.terminate()
    wait(lambda: process.poll() is not None, "clean agent shutdown")
    assert process.returncode == 0, process.returncode
    pump(.05)


try:
    own(True)
    start()
    finished(begin("untrusted", outsider), "Only the registered")
    finished(begin("bad\ncookie"), "Invalid authentication request")
    finished(begin("unsupported", identities=[("unix-group", {"gid": GLib.Variant("u", 0)})]), "Invalid authentication request")

    plan("success", prompt("success"), (b"PAM_TEXT_INFO Welcome\\nback\nSUCCESS\n", None))
    result = begin("success")
    answer("success")
    finished(result)

    plan("mfa", prompt("mfa"), (b"PAM_PROMPT_ECHO_ON Token:\n", b"123456"), (b"SUCCESS\n", None))
    result = begin("mfa")
    answer("mfa")
    answer("mfa", "123456")
    finished(result)

    for _ in range(3):
        plan("retry", prompt("retry"), (b"PAM_ERROR_MSG Incorrect <&>\nFAILURE\n", None))
    result = begin("retry")
    for _ in range(3):
        answer("retry")
    finished(result, "Authentication failed")

    plan("active", prompt("active", "closed"))
    active = begin("active")
    wait(lambda: not events.empty(), "active request")
    assert events.get_nowait() == "active"
    queued = begin("queued")
    pump(.05)
    finished(begin("active"), "Duplicate")
    finished(call("CancelAuthentication", GLib.Variant("(s)", ("queued",))))
    finished(queued, "Cancelled")
    finished(call("CancelAuthentication", GLib.Variant("(s)", ("active",))))
    finished(active, "Cancelled")
    finished(call("CancelAuthentication", GLib.Variant("(s)", ("missing",))), "Unknown")

    plan("first", prompt("first"), (b"SUCCESS\n", None))
    plan("second", prompt("second"), (b"SUCCESS\n", None))
    first = begin("first")
    second = begin("second")
    answer("first")
    finished(first)
    answer("second")
    finished(second)

    plan("cancel-ui", prompt("cancel-ui", "closed"))
    result = begin("cancel-ui")
    wait(lambda: not events.empty(), "dialog cancellation prompt")
    assert events.get_nowait() == "cancel-ui"
    pump(.1)
    window = subprocess.check_output(["xdotool", "search", "--onlyvisible", "--name", "^Authentication Required$"]).split()[0].decode()
    subprocess.run(["xdotool", "windowfocus", "--sync", window], check=True)
    subprocess.run(["xdotool", "key", "--clearmodifiers", "Escape"], check=True)
    finished(result, "Cancelled")

    for cookie, payload in (("malformed", b"SUCCESS-extra\n"), ("oversized", b"x" * 17000), ("invalid-utf8", b"PAM_TEXT_INFO \xff\n"), ("eof", b"")):
        plan(cookie, (payload, None))
        finished(begin(cookie), "Failed")

    plan("restart", prompt("restart", "closed"))
    result = begin("restart")
    wait(lambda: not events.empty(), "request before authority restart")
    assert events.get_nowait() == "restart"
    count = len(registered)
    own(False)
    finished(result, "Cancelled")
    own(True)
    wait(lambda: len(registered) > count, "authority registration restored")
    plan("after-restart", (b"SUCCESS\n", None))
    finished(begin("after-restart"))

    plan("shutdown", prompt("shutdown", "closed"))
    result = begin("shutdown")
    wait(lambda: not events.empty(), "shutdown prompt")
    assert events.get_nowait() == "shutdown"
    count = len(unregistered)
    stop()
    finished(result, "Cancelled")
    assert len(unregistered) > count

    # A wrong peer UID must be rejected before any cookie is transmitted.
    start(os.getuid() + 1)
    finished(begin("wrong-peer"), "unexpected owner")
    wait(lambda: not events.empty(), "wrong peer disconnected without a cookie")
    assert events.get_nowait() == "peer-rejected"
    stop()
    pump(.05)
    logs.flush()
    logs.seek(0)
    content = logs.read()
    assert "leaked" not in content and "CRITICAL" not in content, content
    assert failures.empty(), list(failures.queue)
    print("desktop-polkit: sender/peer checks, prompts, MFA, retries, cancellation, malformed replies, authority restart and clean shutdown passed")
except Exception:
    logs.flush()
    print((root / "agent.log").read_text())
    raise
finally:
    if process is not None and process.poll() is None:
        process.kill()
        process.wait()
    logs.close()
