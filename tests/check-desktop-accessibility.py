"""Check the native accessibility launcher and the bus it starts in isolation."""

import argparse
import ast
import os
from pathlib import Path
import signal
import subprocess as sp

parser = argparse.ArgumentParser()
parser.add_argument("--launcher", required=True)
args = parser.parse_args()
assert Path(args.launcher).read_bytes()[:4] == b"\x7fELF", "launcher must be a native wrapper"
launcher = sp.Popen([args.launcher], start_new_session=True)
try:
    sp.run(["gdbus", "wait", "--session", "--timeout=10", "org.a11y.Bus"],
           check=True, timeout=15)
    reply = sp.run(["gdbus", "call", "--session", "--dest", "org.a11y.Bus",
                    "--object-path", "/org/a11y/bus", "--method", "org.a11y.Bus.GetAddress"],
                   check=True, capture_output=True, text=True, timeout=15)
    address, = ast.literal_eval(reply.stdout.strip())
    assert address.startswith("unix:"), address
    result = sp.run(["gdbus", "call", "--address", address,
                    "--dest", "org.freedesktop.DBus", "--object-path", "/org/freedesktop/DBus",
                    "--method", "org.freedesktop.DBus.ListNames"],
                   check=True, capture_output=True, text=True, timeout=15)
    assert "org.freedesktop.DBus" in result.stdout, result
    assert launcher.poll() is None, "launcher exited while serving accessibility clients"
    print("PASS native accessibility launcher, address discovery, and private bus requests", flush=True)
finally:
    try:
        os.killpg(launcher.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    launcher.wait(timeout=10)
