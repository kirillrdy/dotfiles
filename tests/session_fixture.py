"""Configuration and readiness helpers for isolated desktop session checks."""
import json
from pathlib import Path
import subprocess
import time


def command(binary, root, wallpaper=None, panel_config=None, panel_style=None):
    root = Path(root)
    if wallpaper is None:
        wallpaper = root / "session-wallpaper.ppm"
        wallpaper.write_bytes(b"P6\n2 2\n255\n" + bytes([20, 40, 80]) * 4)
    if panel_config is None:
        panel_config = root / "session-panel.json"
        panel_config.write_text(json.dumps({"left": [], "center": [], "right": []}))
    style = root / "session-style.css"
    style.write_text("window { color: white; }\n")
    return [str(binary), "serve", str(wallpaper), str(panel_config),
            str(panel_style or style), str(style), str(style)]


def wait_ready(binary, env, process):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        assert process.poll() is None, "Desktop session exited before it was ready"
        result = subprocess.run([str(binary), "ping"], env=env, capture_output=True, timeout=5)
        if result.returncode == 0:
            return
        time.sleep(0.05)
    raise AssertionError("Desktop session did not become ready")
