"""Exercise the native application-window host and verify that it loads no GTK."""
import argparse
import os
from pathlib import Path
import subprocess
import time
from wayland_ui import WaylandUI

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True)
args = parser.parse_args()
ui = WaylandUI(dict(os.environ))
title = "Native Wayland fixture"
for close_with_escape in (True, False):
    process = subprocess.Popen([args.binary], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 10
        while not ui.window(title):
            assert process.poll() is None, process.communicate()
            assert time.monotonic() < deadline, "native window did not map"
            time.sleep(0.02)
        loaded = Path(f"/proc/{process.pid}/maps").read_text()
        assert "libgtk-" not in loaded and "libgdk-3" not in loaded, "native window loaded GTK/GDK"
        ui.focus(title)
        ui.type("Cafe 日本語")
        if close_with_escape:
            ui.key("Escape")
        else:
            ui.run("wlrctl", "toplevel", "close", "title:" + title)
        out, err = process.communicate(timeout=10)
        assert process.returncode == 0, out + err
        assert "PASS GTK-free native window" in err, out + err
        print(err.strip(), flush=True)
    finally:
        if process.poll() is None:
            process.terminate()
            process.communicate(timeout=5)

for accepted in (False, True):
    process = subprocess.Popen([args.binary, "consent"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 10
        while not ui.window("Native consent fixture"):
            assert process.poll() is None, process.communicate()
            assert time.monotonic() < deadline, "native consent did not map"
            time.sleep(0.02)
        loaded = Path(f"/proc/{process.pid}/maps").read_text()
        assert "libgtk-" not in loaded and "libgdk-3" not in loaded, "native consent loaded GTK/GDK"
        ui.focus("Native consent fixture")
        ui.key("alt+s" if accepted else "Return")
        out, err = process.communicate(timeout=10)
        assert process.returncode == 0, out + err
        assert f"PASS GTK-free consent accepted={str(accepted).lower()}" in err, out + err
        print(err.strip(), flush=True)
    finally:
        if process.poll() is None:
            process.terminate()
            process.communicate(timeout=5)
