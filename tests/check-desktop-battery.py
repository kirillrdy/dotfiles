"""Exercise native sysfs battery reads, real Wayland widgets and system policy on a private bus.

Run under dbus-run-session. All power actions go to the mock logind below.
"""
import argparse
import json
import math
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess as sp
import tempfile
import threading
import time
import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--fixture", required=True)
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="desktop-native-battery-", dir="/tmp"))
print(f"Artifacts: {root}", flush=True)
for directory in ("runtime", "config/labwc", "cache", "data", "home", "supplies", "lid/LID0"):
    (root / directory).mkdir(parents=True, exist_ok=True, mode=0o700)
(root / "config/labwc/rc.xml").write_text("<labwc_config/>")
(root / "config/labwc/autostart").write_text("")
(root / "config/labwc/environment").write_text("LABWC_UPDATE_ACTIVATION_ENV=false\n")
(root / "lid/LID0/state").write_text("state: open\n")
supplies = root / "supplies"
env = dict(os.environ, XDG_RUNTIME_DIR=str(root / "runtime"), XDG_CONFIG_HOME=str(root / "config"),
           XDG_CACHE_HOME=str(root / "cache"), XDG_DATA_HOME=str(root / "data"), HOME=str(root / "home"),
           DBUS_SYSTEM_BUS_ADDRESS=os.environ["DBUS_SESSION_BUS_ADDRESS"], G_DEBUG="fatal-criticals",
           GSETTINGS_BACKEND="memory", GDK_BACKEND="wayland", NO_AT_BRIDGE="1", GTK_USE_PORTAL="0",
           GIO_USE_VFS="local", WLR_BACKENDS="headless", WLR_RENDERER="pixman", WLR_HEADLESS_OUTPUTS="1",
           LABWC_UPDATE_ACTIVATION_ENV="false")
for key in ("DISPLAY", "WAYLAND_DISPLAY", "LABWC_PID"):
    env.pop(key, None)
context = GLib.MainContext.default()
processes = []
connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
notifications, actions, queries, held = [], [], [], []
capabilities = {"CanHybridSleep": "yes", "CanHibernate": "yes", "CanPowerOff": "yes"}
fail_actions = set()
hold_capability = False


def wait(check, description, timeout=10):
    until = time.monotonic() + timeout
    while not check():
        while context.pending():
            context.iteration(False)
        assert time.monotonic() < until, description + "\n" + logs()
        time.sleep(.01)


def pump(seconds):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        while context.pending():
            context.iteration(False)
        time.sleep(.005)


def logs():
    return "\n".join(f"{path.name}: {path.read_text()}" for path in root.glob("*.log"))


def start(command, name, **kwargs):
    output = (root / name).open("w")
    process = sp.Popen(command, env=env, stderr=output, stdout=kwargs.pop("stdout", output), **kwargs)
    processes.append(process)
    output.close()
    return process


def own(name):
    connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", GLib.Variant("(su)", (name, 4)), None, 0, 2000, None)


def login_call(conn, sender, path, iface, method, params, invocation):
    if method.startswith("Can"):
        queries.append(method)
        if hold_capability:
            held.append((invocation, method))
        else:
            invocation.return_value(GLib.Variant("(s)", (capabilities[method],)))
    else:
        assert params.unpack() == (False,), "automatic action requested interactive authentication"
        actions.append(method)
        if method in fail_actions:
            invocation.return_dbus_error("org.freedesktop.login1.Error.Failed", "fixture action failure")
        else:
            invocation.return_value(None)


def notify_call(conn, sender, path, iface, method, params, invocation):
    notifications.append(params.unpack())
    invocation.return_value(GLib.Variant("(u)", (len(notifications),)))


login_xml = "<node><interface name='org.freedesktop.login1.Manager'>"
for name in capabilities:
    login_xml += f"<method name='{name}'><arg type='s' direction='out'/></method>"
for name in ("HybridSleep", "Hibernate", "PowerOff"):
    login_xml += f"<method name='{name}'><arg type='b' direction='in'/></method>"
login_xml += "</interface></node>"
own("org.freedesktop.login1")
own("org.freedesktop.Notifications")
registrations = [connection.register_object("/org/freedesktop/login1", Gio.DBusNodeInfo.new_for_xml(login_xml).interfaces[0], login_call, None, None)]
notify_xml = "<node><interface name='org.freedesktop.Notifications'><method name='Notify'>" + "".join(f"<arg type='{typ}' direction='in'/>" for typ in ("s", "u", "s", "s", "s", "as", "a{sv}", "i")) + "<arg type='u' direction='out'/></method></interface></node>"
registrations.append(connection.register_object("/org/freedesktop/Notifications", Gio.DBusNodeInfo.new_for_xml(notify_xml).interfaces[0], notify_call, None, None))


def device(name, **attributes):
    target = supplies / name
    target.mkdir(exist_ok=True)
    for key, value in attributes.items():
        temp = target / ("." + key)
        temp.write_text(str(value) + "\n")
        temp.replace(target / key)


def reset():
    for path in supplies.iterdir():
        shutil.rmtree(path)


def energy(percent=72, status="Discharging", online=0, rate=28800000):
    device("AC", type="Mains", online=online)
    device("BAT0", type="Battery", present=1, scope="System", status=status,
           energy_now=percent * 1000000, energy_full=100000000, power_now=rate)


def read():
    result = sp.run([args.fixture, "--read", str(supplies)], env=env, check=True, capture_output=True, text=True, timeout=5)
    return json.loads(result.stdout.splitlines()[-1])


def call(iface, method, params=None, path="/org/freedesktop/UPower"):
    result = []
    def completed(conn, task):
        try:
            result.append(conn.call_finish(task))
        except GLib.Error as error:
            result.append(error)
    connection.call("org.freedesktop.UPower", path, iface, method, params, None, 0, 5000, None, completed)
    wait(lambda: result, method + " reply")
    if isinstance(result[0], GLib.Error):
        raise result[0]
    return result[0].unpack()


def properties(path="/org/freedesktop/UPower/devices/DisplayDevice", iface="org.freedesktop.UPower.Device"):
    return call("org.freedesktop.DBus.Properties", "GetAll", GLib.Variant("(s)", (iface,)), path)[0]


def critical(percent=1, online=0):
    device("BAT0", energy_now=percent * 1000000, status="Discharging")
    device("AC", online=online)


try:
    assert not read()["present"]
    device("mouse", type="Battery", scope="Device", present=1, capacity=1, status="Discharging")
    assert not read()["present"], "peripheral counted as system battery"
    energy()
    value = read()
    assert value["percent"] == 72 and value["time_to_empty"] == 9000 and value["on_battery"], value
    device("BAT0", energy_now=85000000, status="Charging", power_now=60000000)
    device("AC", online=1)
    value = read()
    assert value["time_to_full"] == 900 and value["state"] == 1 and not value["on_battery"], value
    device("BAT0", status="Not charging", energy_now=80000000, charge_control_end_threshold=80)
    value = read()
    assert value["charge_threshold"] and value["state"] == 5 and value["time_to_full"] == 0, value
    reset()
    device("BAT0", type="Battery", status="Discharging", charge_now=3000000, charge_full=6000000, current_now=-1000000, voltage_now=12000000)
    value = read()
    assert value["percent"] == 50 and value["energy"] == 36 and value["energy_rate"] == 12 and value["time_to_empty"] == 10800, value
    (supplies / "BAT0/voltage_now").unlink()
    value = read()
    assert value["percent"] == 50 and value["energy"] == 0 and value["time_to_empty"] == 10800, value
    reset()
    device("BAT0", type="Battery", status="Discharging", charge_now=1000000, charge_full=2000000, current_now=500000, voltage_min_design=12000000)
    device("BAT1", type="Battery", status="Discharging", energy_now=72000000, energy_full=80000000, power_now=2000000)
    value = read()
    assert math.isclose(value["percent"], 84 / 104 * 100) and value["time_to_empty"] == 37800, value
    device("BAT2", type="Battery", status="Discharging", capacity=20)
    value = read()
    assert math.isclose(value["percent"], 160 / 3) and value["time_to_empty"] == 0, value
    device("BAT2", capacity="nan")
    assert read()["percent"] is None, "partial invalid battery permitted a misleading aggregate"
    reset()
    device("BAT0", type="Battery", status="Discharging", capacity=50)
    assert read()["percent"] == 50 and read()["time_to_empty"] == 0
    for invalid in ("-1", "101", "inf", "nan", "broken", "1e309"):
        device("BAT0", capacity=invalid)
        assert read()["percent"] is None, invalid
    device("BAT0", capacity=50, present="broken")
    assert read()["percent"] is None, "malformed presence was trusted"
    device("BAT0", capacity=50, present=0)
    assert not read()["present"]
    print("PASS sysfs energy/charge units, signed current, multi-battery weighting, peripherals and invalid data", flush=True)

    reset()
    energy()
    compositor = start(["desktop-zig", "compositor-only"], "labwc.log")
    wait(lambda: list((root / "runtime").glob("wayland-*.lock")), "private Wayland compositor")
    env["WAYLAND_DISPLAY"] = next((root / "runtime").glob("wayland-*.lock")).stem
    disposed = sp.run([args.fixture, "--dispose", str(supplies)], env=env, capture_output=True, text=True, timeout=5)
    assert disposed.returncode == 0, disposed.stderr
    ui = start([args.fixture, "--watch", str(supplies)], "widgets.log", stdout=sp.PIPE, text=True)
    updates = queue.Queue()
    def reader():
        for line in ui.stdout:
            updates.put(json.loads(line))
    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    def expect(predicate, description):
        def check():
            while True:
                try:
                    value = updates.get_nowait()
                except queue.Empty:
                    return False
                if predicate(value):
                    return True
        wait(check, description)
    expect(lambda v: v["visible"] and v["text"] == "72%" and v["duration"] == "2∶30", "native battery widgets")
    device("BAT0", energy_now=85000000, status="Charging", power_now=60000000)
    device("AC", online=1)
    expect(lambda v: v["text"] == "85%" and v["icon"] == "battery-level-80-charging-symbolic" and v["duration"] == "0∶15", "charging widgets")
    device("BAT0", energy_now=100000000, status="Full")
    expect(lambda v: v["text"] == "100%" and v["icon"] == "battery-level-100-charged-symbolic", "charged widgets")
    device("BAT0", energy_now=99880000)
    expect(lambda v: v["percent"] == 99.88 and v["icon"] == "battery-level-100-charged-symbolic", "full battery below 100% uses the available charged icon")
    device("BAT0", energy_now=80000000, status="Not charging", charge_control_end_threshold=80)
    expect(lambda v: v["text"] == "80%" and v["icon"] == "battery-level-80-plugged-in-symbolic", "charge limit widgets")
    for percent, title in ((20, "Battery Low"), (5, "Battery Critically Low"), (2, "Battery Almost Empty")):
        critical(percent)
        wait(lambda: any(n[3] == title for n in notifications), title)
        pump(.2)
        assert sum(n[3] == title for n in notifications) == 1, "warning repeated"
    assert [n[6]["urgency"] for n in notifications] == [1, 2, 2], notifications
    device("AC", online=1)
    expect(lambda v: not v["on_battery"], "AC restore")
    reset()
    expect(lambda v: not v["visible"] and not v["present"], "battery removal clears widgets")
    energy(50)
    expect(lambda v: v["visible"] and v["text"] == "50%", "battery hotplug restores widgets")
    ui.terminate()
    assert ui.wait(timeout=5) == 0, logs()
    print("PASS live Wayland widgets, charge limits, hotplug, warning notifications and cancellation", flush=True)

    monitor = start([args.fixture, "--monitor", str(supplies)], "monitor.log")
    wait(lambda: connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", GLib.Variant("(s)", ("org.freedesktop.UPower",)), None, 0, 2000, None).unpack()[0], "native power-status name")
    wait(lambda: properties()["Percentage"] == 50, "native power-status service")
    assert call("org.freedesktop.UPower", "GetDisplayDevice") == ("/org/freedesktop/UPower/devices/DisplayDevice",)
    assert call("org.freedesktop.UPower", "EnumerateDevices")[0] == ["/org/freedesktop/UPower/devices/battery_system"]
    assert properties("/org/freedesktop/UPower", "org.freedesktop.UPower")["OnBattery"]
    assert call("org.freedesktop.UPower", "GetCriticalAction") == ("HybridSleep",)
    (root / "lid/LID0/state").write_text("state: closed\n")
    wait(lambda: properties("/org/freedesktop/UPower", "org.freedesktop.UPower")["LidIsClosed"], "lid compatibility")
    changed = []
    connection.signal_subscribe("org.freedesktop.UPower", "org.freedesktop.DBus.Properties", "PropertiesChanged", "/org/freedesktop/UPower/devices/DisplayDevice", None, 0, lambda *event: changed.append(event[-1].unpack()))
    critical(20)
    wait(lambda: properties()["WarningLevel"] == 3, "compatibility warning")
    wait(lambda: changed, "power status change signal")
    assert not actions, "critical action above action threshold"
    print("PASS core UPower status queries, enumeration, lid state, warning levels and change signals", flush=True)

    # Charging/full readings must not trigger protection even if AC is stale/offline.
    device("BAT0", energy_now=1000000, status="Charging")
    wait(lambda: properties()["State"] == 1, "charging with stale AC reading")
    pump(1.0)
    assert not actions, "charging battery triggered a critical action"
    critical(1)
    wait(lambda: properties()["State"] == 2 and properties()["Percentage"] == 1, "critical countdown starts")
    device("AC", online=1)
    wait(lambda: not properties("/org/freedesktop/UPower", "org.freedesktop.UPower")["OnBattery"], "AC cancels critical countdown")
    pump(1.0)
    assert not actions
    # AC can return while logind capability negotiation is still pending.
    hold_capability = True
    device("AC", online=0)
    wait(lambda: held, "critical capability request held")
    device("AC", online=1)
    invocation, method = held.pop(0)
    hold_capability = False
    invocation.return_value(GLib.Variant("(s)", ("yes",)))
    pump(.5)
    assert not actions, "AC restoration during negotiation did not cancel action"
    # The current reading must be checked even before the periodic monitor sees AC.
    capabilities["CanHybridSleep"] = "no"
    capabilities["CanHibernate"] = "no"
    device("AC", online=0)
    wait(lambda: actions == ["PowerOff"], "power-off fallback")
    pump(1.0)
    assert actions == ["PowerOff"], "critical action repeated in one episode"
    device("AC", online=1)
    wait(lambda: properties()["WarningLevel"] == 1, "critical episode reset")
    capabilities["CanHybridSleep"] = "yes"
    capabilities["CanHibernate"] = "yes"
    fail_actions.add("HybridSleep")
    device("AC", online=0)
    wait(lambda: actions == ["PowerOff", "HybridSleep", "Hibernate"], "failed hybrid sleep falls back to hibernate")
    print("PASS critical grace, AC cancellation, capability negotiation, fallback and one action per episode", flush=True)
    device("AC", online=1)
    wait(lambda: properties()["WarningLevel"] == 1, "reset before pending-call shutdown")
    hold_capability = True
    device("AC", online=0)
    wait(lambda: held, "pending logind call before shutdown")
    monitor.terminate()
    assert monitor.wait(timeout=5) == 0, logs()
    print("PASS clean system-monitor shutdown with a pending logind call and checked allocation ownership", flush=True)
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except sp.TimeoutExpired:
                process.kill()
                process.wait()
    for identifier in registrations:
        connection.unregister_object(identifier)
