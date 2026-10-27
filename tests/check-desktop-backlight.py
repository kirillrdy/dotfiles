"""Native sysfs discovery, logind permission handling and GTK brightness controls."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess as sp
import tempfile
import sys
sys.dont_write_bytecode = True
from backlight_mock import BacklightMock

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--fixture", required=True)
parser.add_argument("--dbus-config")
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="desktop-backlight-check-", dir="/tmp"))
print(f"Artifacts: {root}", flush=True)
mock = BacklightMock(root, args.dbus_config)
env = dict(os.environ, DESKTOP_BACKLIGHT_FIXTURE_ROOT=str(mock.sysfs),
           DBUS_SYSTEM_BUS_ADDRESS=mock.address, G_DEBUG="fatal-criticals", GSETTINGS_BACKEND="memory")
(root / "tools").mkdir()
for tool in ("nmcli", "upower", "wpctl"):
    file = root / "tools" / tool
    file.write_text(f"#!{shutil.which('sh')}\nexit 0\n")
    file.chmod(0o755)
env["PATH"] = str(root / "tools") + os.pathsep + env["PATH"]


def run(*command, success=True):
    result = sp.run([args.fixture, *command], env=env, capture_output=True, text=True, timeout=10)
    assert (result.returncode == 0) == success, result.stderr
    return json.loads(result.stdout) if success and result.stdout else None


try:
    assert run("read")["percent"] == 20
    assert run("step", "-100")["current"] == 20  # 5% key floor.
    assert run("step", "100")["current"] == 400
    assert run("set", "0")["current"] == 4  # 1% slider floor.
    assert run("set", "33.5")["current"] == 134
    before = len(mock.calls)
    run("set", "nan", success=False)
    assert len(mock.calls) == before
    mock.deny = True
    run("set", "70", success=False)
    assert run("read")["current"] == 134, "Permission denial changed sysfs"
    mock.deny = False
    mock.device("z-platform", 20, 100, "platform")
    mock.device("firmware", 10, 100, "firmware")
    mock.device("a-firmware", 30, 200, "firmware")
    assert run("read")["device"] == "a-firmware", "Device selection is not deterministic"
    (mock.sysfs / "a-firmware/max_brightness").write_text("0\n")
    assert run("read")["device"] == "firmware"
    for name in ("firmware", "a-firmware", "z-platform"):
        shutil.rmtree(mock.sysfs / name)
    (mock.sysfs / "intel/max_brightness").write_text("invalid\n")
    run("read", success=False)
    mock.device("intel", 500, 400, "raw")
    run("read", success=False)
    mock.device("intel", 80, 400, "raw")
    mock.delay = 250
    run("controls")
    assert mock.calls[-3:] == [("backlight", "intel", 300), ("backlight", "intel", 152), ("backlight", "intel", 4)], mock.calls
    mock.device("intel", 80, 400, "raw")
    mock.deny = True
    run("controls-denied")
    assert int((mock.sysfs / "intel/brightness").read_text()) == 80
    mock.deny = False
    shutil.rmtree(mock.sysfs / "intel")
    before = len(mock.calls)
    run("read", success=False)
    run("set", "50", success=False)
    run("controls-empty")
    assert len(mock.calls) == before, "Missing device caused a write"
    print("PASS: device discovery, ordering, malformed/absent devices, rounding, key/slider floors, logind denial, queued slider writes and cancellation")
finally:
    mock.stop()
