"""Configuration and readiness helpers for isolated desktop session checks."""
import json
from pathlib import Path
import subprocess
import time


class Processes:
    """Own fixture children and their logs, stopping dependents before parents."""

    def __init__(self, root, env):
        self.root = Path(root)
        self.env = env
        self.children = []

    def track(self, process):
        self.children.append(process)
        return process

    def start(self, command, log, extra=None):
        with (self.root / log).open("w") as output:
            return self.track(subprocess.Popen(
                command, env=self.env | (extra or {}),
                stdout=output, stderr=subprocess.STDOUT,
            ))

    def stop(self, timeout=3):
        for process in reversed(self.children):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        self.children.clear()


def command(binary, root, wallpaper=None, panel_config=None):
    root = Path(root)
    if wallpaper is None:
        wallpaper = root / "session-wallpaper.ppm"
        wallpaper.write_bytes(b"P6\n2 2\n255\n" + bytes([20, 40, 80]) * 4)
    if panel_config is None:
        panel_config = root / "session-panel.json"
        panel_config.write_text(json.dumps({"left": [], "center": [], "right": []}))
    return [str(binary), "serve", str(wallpaper), str(panel_config)]


def wait_ready(binary, env, process):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        assert process.poll() is None, "Desktop session exited before it was ready"
        result = subprocess.run([str(binary), "ping"], env=env, capture_output=True, timeout=5)
        if result.returncode == 0:
            return
        time.sleep(0.05)
    raise AssertionError("Desktop session did not become ready")


import json
from pathlib import Path
import select
import struct
import zlib


def wait_until(predicate, message, timeout=10, interval=0.03, step=None, on_error=None):
    deadline = time.monotonic() + timeout
    while True:
        if step is not None:
            step()
        if predicate():
            return
        if on_error is not None:
            on_error()
        assert time.monotonic() < deadline, message() if callable(message) else message
        time.sleep(interval)


def wait_wayland(runtime_dir, compositor, log_path=None, timeout=10):
    runtime_dir = Path(runtime_dir)

    def ready():
        assert compositor.poll() is None, (
            Path(log_path).read_text(errors="replace") if log_path else "Compositor exited"
        )
        for lock in runtime_dir.glob("wayland-*.lock"):
            sock = lock.stem
            if (runtime_dir / sock).exists():
                return sock
        return "wayland-0" if (runtime_dir / "wayland-0").exists() else None

    result = [None]

    def check():
        result[0] = ready()
        return result[0] is not None

    wait_until(check, "Compositor did not create Wayland socket", timeout=timeout, interval=0.05)
    return result[0]


def terminate_processes(processes, timeout=5):
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def png_size(path):
    data = Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    return struct.unpack(">II", data[16:24])


def read_png(path, max_rows=None):
    data = Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, w, h, idat = 8, 0, 0, bytearray()
    while pos < len(data):
        ln = int.from_bytes(data[pos : pos + 4], "big")
        tag = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + ln]
        pos += 12 + ln
        if tag == b"IHDR":
            w, h = struct.unpack(">II", body[:8])
        elif tag == b"IDAT":
            idat.extend(body)
    raw = zlib.decompress(bytes(idat))
    stride = len(raw) // h
    bpp = (stride - 1) // w
    rows = []
    prev = bytes(w * bpp)
    for y in range(min(h, max_rows) if max_rows else h):
        ft = raw[y * stride]
        row = bytearray(raw[y * stride + 1 : (y + 1) * stride])
        if ft == 1:
            for i in range(bpp, len(row)):
                row[i] = (row[i] + row[i - bpp]) & 255
        elif ft == 2:
            for i in range(len(row)):
                row[i] = (row[i] + prev[i]) & 255
        elif ft == 3:
            for i in range(len(row)):
                row[i] = (row[i] + ((row[i - bpp] if i >= bpp else 0) + prev[i]) // 2) & 255
        elif ft == 4:
            for i in range(len(row)):
                a = row[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
        elif ft != 0:
            raise AssertionError(f"Unsupported PNG filter {ft}")
        out = bytes(row)
        rows.append(out)
        prev = out
    return w, h, rows


def read_png_pixels(path):
    w, h, rows = read_png(path)
    bpp = len(rows[0]) // w
    return w, h, lambda x, y: tuple(rows[y][x * bpp : x * bpp + 3])


class VirtualPointer:
    def __init__(self, binary, env=None, stderr=None, delay=0.0):
        self.process = subprocess.Popen(
            [str(binary)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True
        )
        assert select.select([self.process.stdout], [], [], 5)[0], "Virtual pointer did not start"
        assert self.process.stdout.readline().strip() == "ready"
        self.delay = delay

    def command(self, instruction):
        self.process.stdin.write(instruction + "\n")
        self.process.stdin.flush()
        assert select.select([self.process.stdout], [], [], 5)[0], "Virtual pointer timed out"
        assert self.process.stdout.readline().strip() == "ok"
        if self.delay:
            time.sleep(self.delay)

    def move(self, x, y):
        self.command(f"move {int(x)} {int(y)}")

    def click(self, x, y, post_delay=0.0):
        self.move(x, y)
        self.command("button 1")
        self.command("button 0")
        if post_delay:
            time.sleep(post_delay)

    def close(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


class NotificationsClient:
    name = "org.freedesktop.Notifications"
    path = "/org/freedesktop/Notifications"
    control = "org.dotfiles.Notifications"

    def __init__(self):
        from gi.repository import Gio, GLib
        self.Gio = Gio
        self.GLib = GLib
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION)
        self.signals = []
        self.subscription = self.bus.signal_subscribe(
            None, self.name, None, self.path, None, Gio.DBusSignalFlags.NONE,
            lambda _conn, _sender, _path, _iface, member, params: self.signals.append((member, params.unpack())),
        )

    def pump(self):
        context = self.GLib.MainContext.default()
        while context.iteration(False):
            pass

    def call(self, member, parameters=None, iface=None):
        return self.bus.call_sync(
            self.name, self.path, iface or self.control, member, parameters,
            None, self.Gio.DBusCallFlags.NONE, 5000, None,
        ).unpack()

    def history(self):
        return json.loads(self.call("List")[0])

    def clear(self):
        self.call("Clear")
        time.sleep(0.1)

    def owned(self):
        return self.bus.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "NameHasOwner", self.GLib.Variant("(s)", (self.name,)),
            None, self.Gio.DBusCallFlags.NONE, 5000, None,
        ).unpack()[0]

    def close(self):
        self.bus.signal_unsubscribe(self.subscription)
