"""Exercise the real greeter over a PTY and a private fake greetd socket."""

import argparse
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import struct
import subprocess as sp
import tempfile
import termios
import time


class Greeter:
    def __init__(self, binary, root, remember):
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.settimeout(5)
        path = root / "greetd.sock"
        path.unlink(missing_ok=True)
        self.listener.bind(str(path))
        self.listener.listen()
        self.process = sp.Popen(
            [*binary, "--time", "--remember-file", str(remember),
             "--cmd", "/test/labwc-session", "--session", "Other=/test/other-session"],
            stdin=self.slave, stdout=self.slave, stderr=sp.PIPE,
            env=dict(os.environ, GREETD_SOCK=str(path)),
        )
        self.connection, _ = self.listener.accept()
        self.connection.settimeout(5)
        self.output = bytearray()
        self.expect(b"Username:")

    def drain(self):
        while select.select([self.master], [], [], 0.02)[0]:
            self.output.extend(os.read(self.master, 65536))

    def expect(self, text, after=0):
        deadline = time.monotonic() + 5
        while text not in self.output[after:]:
            assert self.process.poll() is None, self.process.stderr.read()
            assert time.monotonic() < deadline, (text, bytes(self.output[-2000:]))
            self.drain()

    def type(self, text):
        os.write(self.master, text)

    def request(self, kind):
        def exact(n):
            data = bytearray()
            while len(data) < n:
                chunk = self.connection.recv(n - len(data))
                assert chunk, "Unexpected disconnect"
                data.extend(chunk)
            return data

        size, = struct.unpack("=I", exact(4))
        assert 0 < size <= 65536
        value = json.loads(exact(size))
        assert value["type"] == kind, value
        return value

    def reply(self, kind, **fields):
        data = json.dumps(dict(type=kind, **fields)).encode()
        frame = struct.pack("=I", len(data)) + data
        # Exercise partial reads of both the length and the payload.
        for i in range(0, len(frame), 3):
            self.connection.sendall(frame[i:i + 3])
            time.sleep(0.001)

    def prompt(self, kind, text):
        mark = len(self.output)
        self.reply("auth_message", auth_message_type=kind, auth_message=text)
        self.expect(text.encode(), mark)

    def username(self, name=b"alice"):
        self.type(name + b"\r")
        assert self.request("create_session")["username"] == name.decode()

    def cancel_reply(self):
        self.request("cancel_session")
        mark = len(self.output)
        self.reply("success")
        self.expect(b"Username:", mark)

    def finish(self, status=0):
        assert self.process.wait(timeout=5) == status, self.process.stderr.read()
        self.drain()
        assert termios.tcgetattr(self.slave) == self.original, "Terminal not restored"
        assert b"\x1b[?1049l" in self.output, "Alternate screen not restored"

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.connection.close()
        self.listener.close()
        os.close(self.master)
        os.close(self.slave)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--subcommand")
    args = parser.parse_args()
    binary = [str(args.binary.absolute())]
    if args.subcommand:
        binary.append(args.subcommand)
    with tempfile.TemporaryDirectory(prefix="desktop-greeter-check-") as directory:
        root = Path(directory)
        remember = root / "last-user"

        def case(test):
            greeter = Greeter(binary, root, remember)
            try:
                test(greeter)
            finally:
                greeter.close()

        def successful(g):
            g.username('alïce'.encode())
            g.reply("auth_message", auth_message_type="info", auth_message="Scan your finger")
            assert g.request("post_auth_message_response")["response"] is None
            g.reply("auth_message", auth_message_type="error", auth_message="Use your password")
            assert g.request("post_auth_message_response")["response"] is None
            g.prompt("secret", "Password:")
            password = 'unique-secret-"\\-日本'
            g.type(password.encode() + b"\r")
            assert g.request("post_auth_message_response")["response"] == password
            g.prompt("visible", "Verification code:")
            g.type(b"123456\r")
            assert g.request("post_auth_message_response")["response"] == "123456"
            assert not remember.exists(), "Remembered a user before session success"
            g.reply("success")
            assert g.request("start_session") == dict(
                type="start_session", cmd=["/test/labwc-session"], env=[])
            g.reply("success")
            g.finish()
            assert password.encode() not in g.output, "Password echoed to terminal"
            assert remember.read_text() == 'alïce'
            assert remember.stat().st_mode & 0o777 == 0o600

        case(successful)

        def retry(g):
            g.type(b"\r")
            assert g.request("create_session")["username"] == 'alïce'
            g.prompt("secret", "Password:")
            g.type(b"wrong-secret\r")
            g.request("post_auth_message_response")
            g.reply("error", error_type="auth_error", description="Authentication failed")
            g.cancel_reply()
            g.expect(b"Authentication failed")
            g.type(b"\r")
            g.request("create_session")
            # Passwordless PAM success must also work.
            g.reply("success")
            g.request("start_session")
            g.reply("error", error_type="error", description="Session unavailable")
            g.cancel_reply()
            g.expect(b"Session unavailable")
            g.process.send_signal(signal.SIGTERM)
            g.finish(1)
            assert b"wrong-secret" not in g.output

        case(retry)

        def cancellation(g):
            g.type(b"\r")
            g.request("create_session")
            g.prompt("secret", "Password:")
            g.type(b"abandoned-secret")
            g.drain()
            g.type(b"\x1b")
            g.cancel_reply()
            g.expect(b"Login cancelled")
            g.process.send_signal(signal.SIGINT)
            g.finish(1)
            assert b"abandoned-secret" not in g.output

        case(cancellation)

        def editing_and_session(g):
            g.type(b"\x15bobX\x7f\x1bOQ")
            g.expect(b"Session: Other")
            g.type(b"\r")
            assert g.request("create_session")["username"] == "bob"
            g.reply("success")
            assert g.request("start_session")["cmd"] == ["/test/other-session"]
            g.reply("success")
            g.finish()

        case(editing_and_session)

        def invalid_frame(g):
            g.type(b"\r")
            g.request("create_session")
            g.connection.sendall(struct.pack("=I", 65537))
            g.finish(1)

        case(invalid_frame)

        def disconnected(g):
            g.type(b"\r")
            g.request("create_session")
            g.connection.sendall(struct.pack("=I", 100) + b"{")
            g.connection.shutdown(socket.SHUT_RDWR)
            g.finish(1)

        case(disconnected)

        def terminated(g):
            g.type(b"\r")
            g.request("create_session")
            g.process.send_signal(signal.SIGTERM)
            g.finish(1)

        case(terminated)
    print("desktop-greeter: fragmented IPC, PAM prompts, masking, Unicode, retries, "
          "cancellation, sessions, remembered user, disconnects and terminal restoration passed")


if __name__ == "__main__":
    main()
