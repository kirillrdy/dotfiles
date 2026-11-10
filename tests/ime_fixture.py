"""A deterministic input-method-v2 peer for native text-input integration checks."""
import os
import socket
import struct
import time
from wayland_ui import VirtualKeyboard


class InputMethod(VirtualKeyboard):
    def __init__(self, env):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(5)
        self.socket.connect(os.path.join(env["XDG_RUNTIME_DIR"], env["WAYLAND_DISPLAY"]))
        self.pending = bytearray()
        self.popup_rect = None
        self.popup_id = None
        self.next_id = 7
        self.popup_open = False
        self.grab_id = None
        self.keys = []
        self.send(1, 1, struct.pack("<I", 2))
        self.send(1, 0, struct.pack("<I", 3))
        globals = {}
        for obj, opcode, data in self.events(3):
            if obj == 2 and opcode == 0:
                name, length = struct.unpack_from("<II", data)
                globals[data[8:8 + length - 1].decode()] = name
        for interface, obj in (("wl_seat", 4), ("zwp_input_method_manager_v2", 5)):
            encoded = self.string(interface)
            self.send(2, 0, struct.pack("<I", globals[interface]) + encoded + struct.pack("<II", 1, obj))
        self.globals = globals
        self.serial = 0
        self.active = False
        self.text = None
        self.cursor = 0
        self.send(5, 0, struct.pack("<II", 4, 6))
        self.roundtrip()

    @staticmethod
    def string(text):
        value = text.encode() + b"\0"
        return struct.pack("<I", len(value)) + value + b"\0" * (-len(value) % 4)

    def allocate(self):
        result = self.next_id
        self.next_id += 1
        return result

    def roundtrip(self):
        callback = self.allocate()
        self.send(1, 0, struct.pack("<I", callback))
        for obj, opcode, data in self.events(callback):
            if obj == self.grab_id and opcode == 1:
                self.keys.append(struct.unpack("<IIII", data))
            if obj == self.popup_id and opcode == 0:
                self.popup_rect = struct.unpack("<iiii", data)
            if obj != 6:
                continue
            if opcode == 0:
                self.active = True
            elif opcode == 1:
                self.active = False
            elif opcode == 2:
                length = struct.unpack_from("<I", data)[0]
                self.text = data[4:4 + length - 1].decode() if length else ""
                offset = 4 + (length + 3) // 4 * 4
                self.cursor = struct.unpack_from("<I", data, offset)[0]
            elif opcode == 5:
                self.serial += 1
            elif opcode == 6:
                raise AssertionError("input method unexpectedly unavailable")

    def wait(self, condition, message):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            self.roundtrip()
            if condition():
                return
            # Acknowledge the latest surrounding/cursor state, even when an
            # earlier composition update was already in flight on the wire.
            if self.active:
                self.send(6, 3, struct.pack("<I", self.serial))
            time.sleep(.02)
        raise AssertionError(message)

    def preedit(self, value):
        length = len(value.encode())
        self.send(6, 1, self.string(value) + struct.pack("<ii", length, length))
        self.send(6, 3, struct.pack("<I", self.serial))
        self.roundtrip()

    def commit(self, value, before=0, after=0):
        self.send(6, 1, self.string("") + struct.pack("<ii", 0, 0))
        self.send(6, 0, self.string(value))
        self.send(6, 2, struct.pack("<II", before, after))
        self.send(6, 3, struct.pack("<I", self.serial))
        self.roundtrip()

    def grab(self):
        self.grab_id = self.allocate()
        self.send(6, 5, struct.pack("<I", self.grab_id))
        self.roundtrip()

    def release(self):
        self.send(self.grab_id, 0, b"")
        self.roundtrip()
        self.grab_id = None

    def stale(self, value):
        self.send(6, 0, self.string(value))
        self.send(6, 3, struct.pack("<I", self.serial - 1))
        self.roundtrip()
        time.sleep(.1)
        self.roundtrip()

    def popup(self):
        compositor, shm = self.allocate(), self.allocate()
        for interface, obj in (("wl_compositor", compositor), ("wl_shm", shm)):
            self.send(2, 0, struct.pack("<I", self.globals[interface]) + self.string(interface) + struct.pack("<II", 1, obj))
        surface, popup, pool, buffer = [self.allocate() for _ in range(4)]
        self.popup_id = popup
        self.popup_objects = (surface, popup, pool, buffer)
        self.send(compositor, 0, struct.pack("<I", surface))
        self.send(6, 4, struct.pack("<II", popup, surface))
        fd = os.memfd_create("native-ime-popup")
        try:
            pixels = struct.pack("<I", 0xff00cc00) * (100 * 24)
            os.write(fd, pixels)
            self.send(shm, 0, struct.pack("<II", pool, len(pixels)), fd)
        finally:
            os.close(fd)
        self.send(pool, 0, struct.pack("<Iiiiii", buffer, 0, 100, 24, 400, 0))
        self.send(surface, 1, struct.pack("<Iii", buffer, 0, 0))
        self.send(surface, 2, struct.pack("<iiii", 0, 0, 100, 24))
        self.send(surface, 6, b"")
        self.popup_open = True
        self.wait(lambda: self.popup_rect is not None, "IME popup did not receive cursor geometry")
        assert self.popup_rect[2:] == (1, 37), self.popup_rect

    def close(self):
        if self.popup_open:
            surface, popup, pool, buffer = self.popup_objects
            self.send(popup, 0, b"")
            self.send(surface, 0, b"")
            self.send(buffer, 0, b"")
            self.send(pool, 1, b"")
        self.send(6, 6, b"")
        self.roundtrip()
        self.socket.close()
