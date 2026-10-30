"""Drive real GTK dialogs through a private wlroots compositor."""
import array
import os
import socket
import struct
import subprocess as sp
import time


class WaylandUI:
    def __init__(self, env):
        self.env = env

    def run(self, *command, check=True):
        result = sp.run(command, env=self.env, capture_output=True, text=True, timeout=5)
        assert not check or result.returncode == 0, (command, result.stderr)
        return result

    def window(self, title):
        result = self.run("wlrctl", "toplevel", "find", "title:" + title, check=False)
        assert result.returncode in (0, 1), result.stderr
        return title if result.returncode == 0 else None

    def focus(self, title):
        self.run("wlrctl", "toplevel", "focus", "title:" + title)
        deadline = time.monotonic() + 5
        while self.run("wlrctl", "toplevel", "find", "title:" + title, "state:active", check=False).returncode:
            assert time.monotonic() < deadline, "focus: " + title
            time.sleep(0.01)

    def key(self, combination):
        *modifiers, key = combination.split("+")
        # GTK accelerators need ordinary evdev codes, rather than the compact
        # custom maps used by text injection tools.
        codes = {"Return": 28, "Escape": 1, "l": 38, "s": 31, "g": 34}
        mask = sum({"ctrl": 4, "alt": 8}[modifier] for modifier in modifiers)
        with VirtualKeyboard(self.env) as keyboard:
            keyboard.key(codes[key], mask)

    def type(self, text):
        self.run("wtype", "-d", "1", "--", text)


class VirtualKeyboard:
    """Send physical key codes on the private compositor's virtual keyboard."""
    def __init__(self, env):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(5)
        self.socket.connect(os.path.join(env["XDG_RUNTIME_DIR"], env["WAYLAND_DISPLAY"]))
        self.pending = bytearray()
        self.send(1, 1, struct.pack("<I", 2))  # wl_display.get_registry
        self.send(1, 0, struct.pack("<I", 3))  # wl_display.sync
        globals = {}
        for obj, opcode, data in self.events(3):
            if obj == 2 and opcode == 0:
                name, length = struct.unpack_from("<II", data)
                globals[data[8:8 + length - 1].decode()] = name
        for interface, obj in (("wl_seat", 4), ("zwp_virtual_keyboard_manager_v1", 5)):
            text = interface.encode() + b"\0"
            payload = struct.pack("<II", globals[interface], len(text)) + text
            payload += b"\0" * (-len(text) % 4) + struct.pack("<II", 1, obj)
            self.send(2, 0, payload)  # wl_registry.bind
        self.send(5, 0, struct.pack("<II", 4, 6))
        keymap = b'''xkb_keymap {
            xkb_keycodes { include "evdev+aliases(qwerty)" };
            xkb_types { include "complete" };
            xkb_compatibility { include "complete" };
            xkb_symbols { include "pc+us+inet(evdev)" };
        };\0'''
        fd = os.memfd_create("portal-keymap")
        try:
            os.write(fd, keymap)
            self.send(6, 0, struct.pack("<II", 1, len(keymap)), fd)
        finally:
            os.close(fd)
        self.sync(7)

    def send(self, obj, opcode, data, fd=None):
        message = struct.pack("<IHH", obj, opcode, len(data) + 8) + data
        if fd is None:
            self.socket.sendall(message)
        else:
            assert self.socket.sendmsg([message], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))]) == len(message)

    def events(self, callback):
        while True:
            while len(self.pending) < 8:
                self.receive()
            obj, opcode, size = struct.unpack_from("<IHH", self.pending)
            assert size >= 8, "invalid Wayland message size"
            while len(self.pending) < size:
                self.receive()
            data = bytes(self.pending[8:size])
            del self.pending[:size]
            assert not (obj == 1 and opcode == 0), ("Wayland protocol error", data)
            if obj == callback and opcode == 0:
                return
            yield obj, opcode, data

    def receive(self):
        data = self.socket.recv(65536)
        assert data, "compositor disconnected"
        self.pending.extend(data)

    def sync(self, callback):
        self.send(1, 0, struct.pack("<I", callback))
        list(self.events(callback))

    def key(self, code, modifiers):
        self.send(6, 2, struct.pack("<IIII", modifiers, 0, 0, 0))
        stamp = int(time.monotonic() * 1000) & 0xffffffff
        for state in (1, 0):
            self.send(6, 1, struct.pack("<III", stamp, code, state))
        self.send(6, 2, struct.pack("<IIII", 0, 0, 0, 0))
        self.sync(8)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.socket.close()
