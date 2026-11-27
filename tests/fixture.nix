{ pkgs }:
# Compile fixtures in derivations and execute integration checks inside NixOS.
{
  name,
  nativeBuildInputs ? [ ],
  python ? pkgs.python3,
  pygobject ? false,
  withDesktop ? false,
  fixture ? null,
  gtkEnv ? false,
  iconTheme ? gtkEnv,
  fonts ? false,
  fontDirs ? pkgs.lib.optional fonts pkgs.dejavu_fonts,
  memorySettings ? false,
  noAtBridge ? false,
  runtimeDir ? false,
  cacheDir ? false,
  headless ? false,
  env ? { },
  script,
}:
let
  inherit (pkgs) lib;
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  pythonHelpers = pkgs.runCommand "test-python-helpers" { } ''
    mkdir -p "$out"
    cat > "$out/audio_server.py" <<'PY'
    import os
    from pathlib import Path
    import signal
    import subprocess as sp
    import time

    WP_CONFIG = """
    wireplumber.profiles = { main = {
      monitor.alsa = disabled
      monitor.alsa-midi = disabled
      monitor.bluez = disabled
      monitor.v4l2 = disabled
      monitor.libcamera = disabled
      support.logind = disabled
    } }
    """
    PW_CONFIG = """
    context.properties = { core.daemon = true core.name = pipewire-0 support.dbus = false
      default.clock.rate = 48000 default.clock.quantum = 256 }
    context.spa-libs = { audio.convert.* = audioconvert/libspa-audioconvert
      support.* = support/libspa-support audiotestsrc = audiotestsrc/libspa-audiotestsrc }
    context.modules = [
      { name = libpipewire-module-protocol-native }
      { name = libpipewire-module-access args = { access.force = unrestricted } }
      { name = libpipewire-module-metadata }
      { name = libpipewire-module-spa-node-factory }
      { name = libpipewire-module-client-node }
      { name = libpipewire-module-adapter }
      { name = libpipewire-module-link-factory }
      { name = libpipewire-module-session-manager }
    ]
    context.objects = [
      { factory = adapter args = { factory.name = support.null-audio-sink
        node.name = fixture-speakers node.description = "Fixture speakers"
        media.class = Audio/Sink audio.position = [ FL FR ] } }
      { factory = adapter args = { factory.name = support.null-audio-sink
        node.name = fixture-headphones node.description = "Fixture headphones"
        media.class = Audio/Sink audio.position = [ FL FR ] } }
      { factory = adapter args = { factory.name = audiotestsrc
        node.name = fixture-microphone node.description = "Fixture microphone"
        media.class = Audio/Source audio.position = [ MONO ] } }
    ]
    """

    class AudioServer:
        @staticmethod
        def configure(root, config_home):
            fragment = config_home / "wireplumber/wireplumber.conf.d"
            fragment.mkdir(parents=True, exist_ok=True)
            (fragment / "90-fixture.conf").write_text(WP_CONFIG)
            (root / "pipewire.conf").write_text(PW_CONFIG)

        def __init__(self, root, env):
            self.root, self.env = root, env
            self.pipewire = self.wireplumber = self.pulse = None
            self.suspended = False
            self.cached = {"volume": 50, "muted": True, "mic_muted": False}
            self.configure(root, Path(env["XDG_CONFIG_HOME"]))
            env["PIPEWIRE_REMOTE"] = "pipewire-0"
            env["PULSE_SERVER"] = "unix:" + str(Path(env["XDG_RUNTIME_DIR"]) / "pulse/native")
            env["PULSE_RUNTIME_PATH"] = str(Path(env["XDG_RUNTIME_DIR"]) / "pulse")
            for key in ("PIPEWIRE_RUNTIME_DIR", "PIPEWIRE_CONFIG_DIR", "WIREPLUMBER_CONFIG_DIR", "WIREPLUMBER_DATA_DIR"):
                env.pop(key, None)

        def launch(self, command, log):
            with (self.root / log).open("w") as output:
                return sp.Popen(command, env=self.env, stdout=output, stderr=sp.STDOUT)

        def command(self, *args):
            return sp.run(["wpctl", *args], env=self.env, capture_output=True, text=True, check=True, timeout=3)

        def start(self):
            self.pipewire = self.launch(["pipewire", "-c", str(self.root / "pipewire.conf")], "audio-pipewire.log")
            deadline = time.monotonic() + 8
            while not (Path(self.env["XDG_RUNTIME_DIR"]) / "pipewire-0").exists():
                assert self.pipewire.poll() is None, (self.root / "audio-pipewire.log").read_text()
                assert time.monotonic() < deadline, "private PipeWire socket"
                time.sleep(.02)
            self.wireplumber = self.launch(["wireplumber"], "audio-wireplumber.log")
            while True:
                try:
                    sink = self.command("get-volume", "@DEFAULT_AUDIO_SINK@").stdout
                    source = self.command("get-volume", "@DEFAULT_AUDIO_SOURCE@").stdout
                    if not sink.startswith("Volume:") or not source.startswith("Volume:"):
                        raise ValueError("default audio nodes are not ready")
                    break
                except (sp.CalledProcessError, sp.TimeoutExpired, ValueError):
                    assert self.wireplumber.poll() is None, (self.root / "audio-wireplumber.log").read_text()
                    assert time.monotonic() < deadline, "private audio defaults"
                    time.sleep(.05)

            self.pulse = self.launch(["pipewire-pulse"], "audio-pulse.log")
            while not (Path(self.env["XDG_RUNTIME_DIR"]) / "pulse/native").exists():
                assert self.pulse.poll() is None, (self.root / "audio-pulse.log").read_text()
                assert time.monotonic() < deadline, "private pulse socket"
                time.sleep(.02)

        def state(self):
            if self.pipewire is None or self.suspended:
                return self.cached
            sink = self.command("get-volume", "@DEFAULT_AUDIO_SINK@").stdout
            source = self.command("get-volume", "@DEFAULT_AUDIO_SOURCE@").stdout
            self.cached = {"volume": round(float(sink.split()[1]) * 100, 6), "muted": "MUTED" in sink, "mic_muted": "MUTED" in source}
            return self.cached

        def suspend(self):
            self.cached = self.state()
            self.pipewire.send_signal(signal.SIGSTOP)
            self.suspended = True

        def resume(self):
            if self.suspended:
                self.pipewire.send_signal(signal.SIGCONT)
                self.suspended = False

        def stop(self):
            self.resume()
            for process in (self.pulse, self.wireplumber, self.pipewire):
                if process and process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except sp.TimeoutExpired:
                        process.kill()
                        process.wait()
            self.wireplumber = self.pipewire = None
    PY
    cat > "$out/backlight_mock.py" <<'PY'
    import os
    from pathlib import Path
    import subprocess as sp
    import threading
    from gi.repository import Gio, GLib

    class BacklightMock:
        def __init__(self, root, config=None, on_set=None):
            self.root = Path(root)
            self.sysfs = self.root / "backlight"
            self.sysfs.mkdir()
            self.device("intel", 80, 400, "raw")
            self.calls = []
            self.deny = False
            self.delay = 0
            self.on_set = on_set
            self.loop = GLib.MainLoop()
            self.thread = threading.Thread(target=self.loop.run, daemon=True)
            self.thread.start()
            self.log = (self.root / "backlight-bus.log").open("w")
            command = ["dbus-daemon", "--nofork", "--print-address=1",
                       "--config-file=" + str(config) if config else "--session"]
            self.bus = sp.Popen(command, stdout=sp.PIPE, stderr=self.log, text=True)
            self.address = self.bus.stdout.readline().strip()
            if not self.address.startswith("unix:"):
                raise RuntimeError((self.root / "backlight-bus.log").read_text())
            self.conn = Gio.DBusConnection.new_for_address_sync(self.address,
                Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                None, None)
            self.conn.set_exit_on_close(False)
            xml = """<node><interface name="org.freedesktop.login1.Session"><method name="SetBrightness">
            <arg type="s" direction="in"/><arg type="s" direction="in"/>
            <arg type="u" direction="in"/></method></interface></node>"""
            self.registration = self.conn.register_object("/org/freedesktop/login1/session/auto",
                Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], self.method, None, None)
            self.conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                "RequestName", GLib.Variant("(su)", ("org.freedesktop.login1", 0)), None, 0, 3000, None)

        def device(self, name, current, maximum, kind):
            directory = self.sysfs / name
            directory.mkdir(exist_ok=True)
            for attribute, value in (("brightness", current), ("max_brightness", maximum), ("type", kind)):
                (directory / attribute).write_text(str(value) + "\n")

        def method(self, conn, sender, path, interface, method, parameters, invocation):
            subsystem, name, value = parameters.unpack()
            self.calls.append((subsystem, name, value))
            def finish():
                if self.deny:
                    invocation.return_dbus_error("org.freedesktop.DBus.Error.AccessDenied", "Fixture: inactive session")
                    return False
                device = self.sysfs / name
                if subsystem != "backlight" or "/" in name or not device.exists():
                    invocation.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "Missing backlight")
                    return False
                maximum = int((device / "max_brightness").read_text())
                assert 1 <= value <= maximum
                (device / "brightness").write_text(str(value) + "\n")
                if self.on_set:
                    self.on_set(value / maximum * 100)
                invocation.return_value(GLib.Variant("()", ()))
                return False
            if self.delay:
                GLib.timeout_add(self.delay, finish)
            else:
                finish()

        def stop(self):
            self.conn.close_sync(None)
            self.bus.terminate()
            self.bus.wait(timeout=5)
            self.loop.quit()
            self.thread.join(timeout=3)
            self.log.close()
    PY
    cat > "$out/network_server.py" <<'PY'
    from gi.repository import Gio, GLib

    NAME = 'org.freedesktop.NetworkManager'
    ROOT = '/org/freedesktop/NetworkManager'
    DEVICE = ROOT + '/Devices/1'
    AP = ROOT + '/AccessPoint/1'
    PROFILE = ROOT + '/Settings/1'
    ACTIVE = ROOT + '/ActiveConnection/1'
    OM = 'org.freedesktop.DBus.ObjectManager'
    PROPS = 'org.freedesktop.DBus.Properties'
    V = GLib.Variant

    class Server:
        def __init__(self, address):
            self.bus = Gio.DBusConnection.new_for_address_sync(address,
                Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
            self.objects = {}
            self.registrations = []
            self.calls = []
            self.deny = False
            self.activation_fail = False
            self.delay = False
            self.stale = False
            self.secret_reads = []
            self.secrets = {'802-11-wireless-security': {'psk': V('s', 'stored-wifi-secret')}, '802-1x': {'private-key-password': V('s', 'stored-key-secret')}}
            self.settings = {
                'connection': {'id': V('s', 'Saved'), 'uuid': V('s', 'test-uuid'), 'type': V('s', '802-11-wireless')},
                '802-11-wireless': {'ssid': V('ay', b'Saved')},
                '802-11-wireless-security': {'key-mgmt': V('s', 'wpa-psk')},
                '802-1x': {'eap': V('as', ['tls'])},
                'proxy': {'method': V('i', 0), 'pac-url': V('s', 'https://proxy.example/config')},
                'ipv4': {'method': V('s', 'manual'), 'dns': V('au', [0x01010101])},
            }
            self.add('/org/freedesktop', OM, {}, {'GetManagedObjects': ("", 'a{oa{sa{sv}}}')})
            self.add(ROOT, NAME, {'WirelessEnabled': V('b', True), 'WirelessHardwareEnabled': V('b', True), 'PrimaryConnection': V('o', '/')}, {
                'ActivateConnection': ('ooo', 'o'), 'AddAndActivateConnection': ('a{sa{sv}}oo', 'oo'), 'DeactivateConnection': ('o', "")})
            self.add(DEVICE, NAME+'.Device', {'DeviceType': V('u', 2), 'Interface': V('s', 'wlan0'), 'State': V('u', 30), 'Managed': V('b', True), 'ActiveConnection': V('o', '/')}, {'Disconnect': ("", "")})
            self.add(DEVICE, NAME+'.Device.Wireless', {'AccessPoints': V('ao', [AP]), 'ActiveAccessPoint': V('o', '/')}, {'RequestScan': ('a{sv}', "")})
            self.add(AP, NAME+'.AccessPoint', {'Ssid': V('ay', b'Cafe: Tokyo\\5G'), 'Strength': V('y', 83), 'Flags': V('u', 1), 'WpaFlags': V('u', 0), 'RsnFlags': V('u', 0x100)}, {})
            self.add(ROOT+'/Settings', NAME+'.Settings', {}, {'AddConnection': ('a{sa{sv}}', 'o')})
            self.add(PROFILE, NAME+'.Settings.Connection', {'VersionId': V('t', 1)}, {'GetSettings': ("", 'a{sa{sv}}'), 'GetSecrets': ('s', 'a{sa{sv}}'), 'Update2': ('a{sa{sv}}ua{sv}', 'a{sv}'), 'Update': ('a{sa{sv}}', ""), 'Delete': ("", "")}, '<signal name="Updated"/>')
            self.own()

        def own(self):
            self.bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName', V('(su)', (NAME, 0)), None, 0, -1, None)

        def add(self, path, iface, properties, methods, signals=""):
            def args(signature, direction):
                result = ""
                remaining = signature
                while remaining:
                    def consume(s, i=0):
                        if s[i] == 'a': return consume(s, i+1)
                        if s[i] in '({':
                            end = ')' if s[i] == '(' else '}'
                            i += 1
                            while s[i] != end: i = consume(s, i)
                            return i+1
                        return i+1
                    n = consume(remaining)
                    result += f'<arg type="{remaining[:n]}" direction="{direction}"/>'
                    remaining = remaining[n:]
                return result
            xml = '<node><interface name="'+iface+'">'
            for key, val in properties.items(): xml += f'<property name="{key}" type="{val.get_type_string()}" access="readwrite"/>'
            for key, (ins, outs) in methods.items(): xml += '<method name="'+key+'">'+args(ins, 'in')+args(outs, 'out')+'</method>'
            xml += signals+'</interface></node>'
            info = Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0]
            reg = self.bus.register_object(path, info, self.method, self.get, self.set)
            self.registrations.append(reg)
            self.objects.setdefault(path, {})[iface] = properties
            if path != '/org/freedesktop':
                self.bus.emit_signal(None, '/org/freedesktop', OM, 'InterfacesAdded', V('(oa{sa{sv}})', (path, {iface: properties})))

        def get(self, bus, sender, path, iface, key): return self.objects[path][iface][key]

        def set(self, bus, sender, path, iface, key, value):
            self.calls.append(('Set', key, value.unpack()))
            if self.deny: return False
            self.change(path, iface, {key: value})
            return True

        def change(self, path, iface, values):
            self.objects[path][iface].update(values)
            self.bus.emit_signal(None, path, PROPS, 'PropertiesChanged', V('(sa{sv}as)', (iface, values, [])))

        def method(self, bus, sender, path, iface, method, params, invocation):
            self.calls.append((method, params.unpack()))
            if self.deny and method not in ('GetManagedObjects', 'GetSettings'):
                invocation.return_dbus_error(NAME+'.PermissionDenied', 'fixture permission denied')
                return
            if self.delay and method in ('RequestScan', 'GetSecrets', 'Update2'):
                reply = V('(a{sa{sv}})', ({},)) if method == 'GetSecrets' else V('(a{sv})', ({},)) if method == 'Update2' else V('()', ())
                GLib.timeout_add(500, lambda: (invocation.return_value(reply), False)[1])
                return
            if method == 'GetManagedObjects':
                invocation.return_value(V('(a{oa{sa{sv}}})', ({p:i for p,i in self.objects.items() if p != '/org/freedesktop'},)))
            elif method == 'GetSettings': invocation.return_value(V('(a{sa{sv}})', (self.settings,)))
            elif method == 'GetSecrets':
                group = params.unpack()[0]
                self.secret_reads.append(group)
                invocation.return_value(V('(a{sa{sv}})', ({group: self.secrets.get(group, {})},)))
            elif method == 'AddConnection':
                self.last_added = params.unpack()[0]
                invocation.return_value(V('(o)', (ROOT+'/Settings/2',)))
            elif method == 'Update2' and (self.stale or params.unpack()[2].get('version-id') != self.objects[PROFILE][NAME+'.Settings.Connection']['VersionId'].unpack()):
                invocation.return_dbus_error(NAME+'.Settings.VersionIdMismatch', 'Profile changed since the editor opened')
            elif method in ('Update', 'Update2'):
                self.settings = {group: {key: params.get_child_value(0).lookup_value(group, None).lookup_value(key, None) for key in values} for group, values in params.unpack()[0].items()}
                self.change(PROFILE, NAME+'.Settings.Connection', {'VersionId': V('t', self.objects[PROFILE][NAME+'.Settings.Connection']['VersionId'].unpack()+1)})
                self.bus.emit_signal(None, path, iface, 'Updated', None)
                invocation.return_value(V('(a{sv})', ({},)) if method == 'Update2' else V('()', ()))
            elif method in ('ActivateConnection', 'AddAndActivateConnection'):
                if method == 'AddAndActivateConnection':
                    self.last_added = params.unpack()[0]
                    profile = PROFILE
                else: profile = params.unpack()[0]
                if ACTIVE not in self.objects:
                    self.add(ACTIVE, NAME+'.Connection.Active', {'Connection': V('o', profile), 'Id': V('s', 'Connected'), 'Type': V('s', '802-11-wireless'), 'State': V('u', 1)}, {})
                else: self.change(ACTIVE, NAME+'.Connection.Active', {'State': V('u', 1)})
                invocation.return_value(V('(o)', (ACTIVE,)) if method == 'ActivateConnection' else V('(oo)', (profile, ACTIVE)))
                def activated():
                    self.change(ACTIVE, NAME+'.Connection.Active', {'State': V('u', 4 if self.activation_fail else 2)})
                    return False
                GLib.timeout_add(50, activated)
            elif method == 'Delete':
                interfaces = self.objects.pop(path)
                self.bus.emit_signal(None, '/org/freedesktop', OM, 'InterfacesRemoved', V('(oas)', (path, list(interfaces))))
                invocation.return_value(V('()', ()))
            else: invocation.return_value(V('()', ()))
    PY
    cat > "$out/session_fixture.py" <<'PY'
    import json
    from pathlib import Path
    import select
    import struct
    import subprocess
    import time
    import zlib

    class Processes:
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

    def write_wallpaper(path, rgb=(20, 40, 80), size=2):
        def chunk(tag, body):
            return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))
        rows = (b"\0" + bytes(rgb) * size) * size
        header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
        Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
        return Path(path)

    def command(binary, root, wallpaper=None, panel_config=None):
        root = Path(root)
        if wallpaper is None:
            wallpaper = write_wallpaper(root / "session-wallpaper.png")
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

    def wait_until(predicate, message, timeout=10, interval=0.03, step=None, on_error=None):
        deadline = time.monotonic() + timeout
        while True:
            if step is not None:
                step()
            result = predicate()
            if result:
                return result
            if on_error is not None:
                on_error()
            assert time.monotonic() < deadline, message() if callable(message) else message
            time.sleep(interval)

    def glib_pump():
        from gi.repository import GLib
        ctx = GLib.MainContext.default()
        while ctx.pending():
            ctx.iteration(False)

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
    PY
    cat > "$out/wayland_ui.py" <<'PY'
    import array
    import os
    import socket
    import struct
    import subprocess as sp
    import time

    class WaylandUI:
        def __init__(self, env):
            self.env = env
            self.keyboard = VirtualKeyboard(env)

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
            codes = {"Return": 28, "Escape": 1, "l": 38, "s": 31, "g": 34}
            mask = sum({"ctrl": 4, "alt": 8}[modifier] for modifier in modifiers)
            with VirtualKeyboard(self.env) as keyboard:
                keyboard.key(codes[key], mask)

        def type(self, text):
            self.run("wtype", "-d", "1", "--", text)

    class VirtualKeyboard:
        def __init__(self, env):
            self.socket = socket.socket(socket.AF_UNIX)
            self.socket.settimeout(5)
            self.socket.connect(os.path.join(env["XDG_RUNTIME_DIR"], env["WAYLAND_DISPLAY"]))
            self.pending = bytearray()
            self.send(1, 1, struct.pack("<I", 2))
            self.send(1, 0, struct.pack("<I", 3))
            globals = {}
            for obj, opcode, data in self.events(3):
                if obj == 2 and opcode == 0:
                    name, length = struct.unpack_from("<II", data)
                    globals[data[8:8 + length - 1].decode()] = name
            for interface, obj in (("wl_seat", 4), ("zwp_virtual_keyboard_manager_v1", 5)):
                text = interface.encode() + b"\0"
                payload = struct.pack("<II", globals[interface], len(text)) + text
                payload += b"\0" * (-len(text) % 4) + struct.pack("<II", 1, obj)
                self.send(2, 0, payload)
            self.send(5, 0, struct.pack("<II", 4, 6))
            keymap = b"""xkb_keymap {
                xkb_keycodes { include "evdev+aliases(qwerty)" };
                xkb_types { include "complete" };
                xkb_compatibility { include "complete" };
                xkb_symbols { include "pc+us+inet(evdev)" };
            };\0"""
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
    PY
  '';
  builtFixture =
    if fixture == null then
      null
    else
      desktop.overrideAttrs (
        {
          pname = fixture.name;
          outputs = [ "out" ];
          buildPhase = ''
            cp -r ${desktop.zigGlobalCache} "$TMPDIR/zig-cache"
            chmod -R u+w "$TMPDIR/zig-cache"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            NIX_LDFLAGS= zig build ${fixture.steps} --prefix "$out" \
              -Doptimize=${if (fixture.debug or false) then "Debug" else "ReleaseSafe"} \
              -Dcpu=${fixture.cpu or (if (fixture.debug or false) then "baseline" else "native")}
          '';
          doCheck = false;
          installPhase = "true";
        }
      );
  headlessScript = ''
    export XDG_RUNTIME_DIR="$TMPDIR/wayland-runtime"
    mkdir -m 700 -p "$XDG_RUNTIME_DIR"
    # Absolute paths survive tests creating their own private runtime directories.
    export WAYLAND_DISPLAY="$XDG_RUNTIME_DIR/wayland-0" GDK_BACKEND=wayland
    export WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1
    ${desktop}/bin/desktop-zig compositor-only > "$TMPDIR/compositor.log" 2>&1 &
    fixture_compositor_pid=$!
    trap 'kill "$fixture_compositor_pid" 2>/dev/null || true' EXIT
    for attempt in $(seq 1 100); do
      test -S "$WAYLAND_DISPLAY" && break
      if ! kill -0 "$fixture_compositor_pid" 2>/dev/null; then
        cat "$TMPDIR/compositor.log" >&2
        exit 1
      fi
      sleep 0.05
    done
    test -S "$WAYLAND_DISPLAY"
  '';
  dbusConfig = "${pkgs.dbus}/share/dbus-1/session.conf";
  dbusRun = "dbus-run-session --config-file=${dbusConfig} --";
  pythonPkg = if pygobject then pkgs.python3.withPackages (p: [ p.pygobject3 ]) else python;
  dataDirs = lib.optional iconTheme "${pkgs.adwaita-icon-theme}/share";
  body =
    if builtins.isFunction script then
      script {
        inherit
          desktop
          dbusConfig
          dbusRun
          headlessScript
          ;
        fixture = builtFixture;
      }
    else
      script;
  runtimeScript = pkgs.writeShellScript "${name}-run" (
    ''
      set -euo pipefail
      export TMPDIR=$(mktemp -d)
      cd "$TMPDIR"
    ''
    + setup
    + body
  );
  setup =
    lib.optionalString (pythonPkg != null) ''
      export PYTHONPATH=${pythonHelpers}
      export PYTHONDONTWRITEBYTECODE=1
    ''
    + lib.optionalString gtkEnv ''
      export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    ''
    + lib.optionalString (dataDirs != [ ]) ''
      export XDG_DATA_DIRS=${lib.concatStringsSep ":" dataDirs}
    ''
    + lib.optionalString memorySettings ''
      export GSETTINGS_BACKEND=memory
    ''
    + lib.optionalString noAtBridge ''
      export NO_AT_BRIDGE=1
    ''
    + lib.optionalString runtimeDir ''
      export XDG_RUNTIME_DIR="$TMPDIR/runtime"
      mkdir -m 700 "$XDG_RUNTIME_DIR"
    ''
    + lib.optionalString cacheDir ''
      export XDG_CACHE_HOME="$TMPDIR/cache"
      mkdir -p "$XDG_CACHE_HOME"
    ''
    + lib.optionalString headless headlessScript;
  runner =
    pkgs.runCommand "${name}-runner"
      (
        {
          nativeBuildInputs =
            lib.optional (pythonPkg != null) pythonPkg
            ++ lib.optional withDesktop desktop
            ++ nativeBuildInputs
            ++ [ pkgs.makeWrapper ];
        }
        // lib.optionalAttrs (fontDirs != [ ]) {
          FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = fontDirs; };
        }
        // env
      )
      ''
        mkdir -p "$out/bin"
        # Preserve setup-hook paths, but run every assertion after the VM boots.
        args=(--prefix PATH : "$PATH")
        for key in FONTCONFIG_FILE GI_TYPELIB_PATH XDG_DATA_DIRS ${lib.concatStringsSep " " (builtins.attrNames env)}; do
          if [[ -v $key ]]; then
            args+=(--set "$key" "''${!key}")
          fi
        done
        makeWrapper ${runtimeScript} "$out/bin/check" "''${args[@]}"
      '';
in
pkgs.testers.runNixOSTest {
  inherit name;
  nodes.machine = {
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    users.users.tester.isNormalUser = true;
    # These contract tests manage private compositors and mock services.
    # Production service wiring is covered separately by desktop-vm.nix.
    environment.systemPackages = [ runner ];
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    with subtest(${builtins.toJSON name}):
        machine.succeed("su - tester -c ${runner}/bin/check", timeout=900)
  '';
}
