"""Fail on retained Zig allocations, owned GObjects, or definitely lost C heap blocks."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess as sp
import sys
import tempfile

sys.dont_write_bytecode = True
from audio_server import AudioServer
from network_server import Server
from gi.repository import GLib
import threading

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True)
parser.add_argument("--valgrind", required=True)
parser.add_argument("--strip", required=True)
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="desktop-memory-check-", dir=os.environ.get("TMPDIR", "/tmp")))
print(f"Memory-check artifacts: {root}", flush=True)
(root / "runtime").mkdir(mode=0o700)
env = dict(os.environ, XDG_RUNTIME_DIR=str(root / "runtime"),
           XDG_CONFIG_HOME=str(root / "config"), XDG_CACHE_HOME=str(root / "cache"),
           XDG_STATE_HOME=str(root / "state"), GSETTINGS_BACKEND="memory",
           NO_AT_BRIDGE="1", GDK_BACKEND="x11", G_DEBUG="gc-friendly,fatal-criticals",
           DESKTOP_MEMORY_TEST_RUN="1", DBUS_SYSTEM_BUS_ADDRESS=os.environ["DBUS_SESSION_BUS_ADDRESS"],
           PATH=os.environ["PATH"])
env.pop("DESKTOP_MEMORY_LEAK_PROBE", None)
# Keep source-level diagnostics for the native run. Valgrind's DWARF reader
# cannot parse this Zig compiler's line-table extensions; retain symbol names.
heap_binary = root / "desktop-memory-tests-valgrind"
shutil.copyfile(args.binary, heap_binary)
heap_binary.chmod(0o755)
sp.run([args.strip, "--strip-debug", str(heap_binary)], check=True)
audio = AudioServer(root, env)


def run(name, probe=None, checked_heap=False):
    child_env = env | ({"DESKTOP_MEMORY_LEAK_PROBE": probe} if probe else {})
    log = root / (name + ".valgrind.log")
    command = [str(heap_binary) if checked_heap else args.binary]
    if checked_heap:
        command = [args.valgrind, "--leak-check=full", "--show-leak-kinds=definite,indirect",
                   "--errors-for-leak-kinds=definite,indirect", "--error-exitcode=97",
                   "--num-callers=30", "--log-file=" + str(log), *command]
    result = sp.run(command, env=child_env, capture_output=True, text=True,
                    timeout=300 if checked_heap else 120)
    output = result.stdout + result.stderr
    (root / (name + ".log")).write_text(output)
    return result.returncode, output, log.read_text() if checked_heap else ""


try:
    network = Server(os.environ["DBUS_SESSION_BUS_ADDRESS"])
    network_loop = GLib.MainLoop()
    network_thread = threading.Thread(target=network_loop.run, daemon=True)
    network_thread.start()
    audio.start()
    status, output, _ = run("tracked-lifetimes")
    assert status == 0, output[-14000:]
    print("PASS tracked allocations and owned-object finalization across repeated teardown", flush=True)
    status, output, heap = run("c-heap-lifetimes", checked_heap=True)
    assert status == 0, output[-4000:] + heap[-14000:]
    assert "definitely lost:" in heap, heap
    print("PASS native heap leak check for repeated service, settings and widget teardown", flush=True)
    status, output, _ = run("zig-leak-control", probe="zig")
    assert status != 0 and "leak" in output.lower(), output
    status, output, _ = run("object-leak-control", probe="object")
    assert status != 0 and "RetainedObjects" in output, output
    status, output, heap = run("c-leak-control", probe="c", checked_heap=True)
    assert status == 97 and re.search(r"37 bytes in 1 blocks? are definitely lost", heap), output[-4000:] + heap[-14000:]
    print("PASS negative controls: deliberate Zig, GObject-reference and C-heap leaks fail", flush=True)
finally:
    audio.stop()
    network_loop.quit()
    network_thread.join(timeout=2)
