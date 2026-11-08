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
