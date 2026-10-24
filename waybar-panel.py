"""JSON data streams for the GNOME-style native Waybar widgets."""

import argparse
import json
import math
import os
import re
import subprocess
import time
from pathlib import Path


CPU_COLORS = ["#0072b3", "#0092e6", "#00a3ff", "#002f3d", "#001d26"]
MEMORY_COLORS = ["#00b35b", "#00ff82", "#aaf5d0"]
NETWORK_COLORS = ["#fce94f", "#ff6e00", "#fb74fb", "#e0006e", "#ff0000"]


def command(*args, timeout=4):
    try:
        return subprocess.run(
            args, capture_output=True, text=True, timeout=timeout, check=True
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def cpu_counters(contents):
    return [int(value) for value in contents.splitlines()[0].split()[1:9]]


def cpu_usage(previous, current):
    delta = [max(0, new - old) for old, new in zip(previous, current)]
    total = sum(delta)
    if not total:
        return [0.0] * 5
    user, nice, system, _idle, wait, irq, softirq, steal = delta
    return [value * 100 / total for value in (user, system, nice, wait, irq + softirq + steal)]


def memory_usage(contents):
    fields = {}
    for line in contents.splitlines():
        key, value = line.split(":", 1)
        fields[key] = int(value.split()[0])
    total = max(1, fields.get("MemTotal", 1))
    cache = max(0, fields.get("Cached", 0) + fields.get("SReclaimable", 0) - fields.get("Shmem", 0))
    buffers = fields.get("Buffers", 0)
    used = max(0, total - fields.get("MemFree", 0) - buffers - cache)
    return [value * 100 / total for value in (used, buffers, cache)], used / 1048576, total / 1048576


def network_counters():
    received = sent = 0
    for line in Path("/proc/net/dev").read_text().splitlines()[2:]:
        name, counters = line.split(":", 1)
        # Match GNOME's aggregate of physical NetworkManager interfaces.
        if not (Path("/sys/class/net") / name.strip() / "device").exists():
            continue
        values = counters.split()
        received += int(values[0])
        sent += int(values[8])
    return received, sent


def rate_text(rate):
    value = max(0, rate) / 1024
    unit = "KiB/s"
    if value >= 1024:
        value /= 1024
        unit = "MiB/s"
    if value >= 1024:
        value /= 1024
        unit = "GiB/s"
    return f'{value:.3g}<span size="62.5%" alpha="65%"> {unit}</span>'


def monitor(values, colors, sequence, markup, tooltip, maximum=100):
    return dict(values=values, colors=colors, sequence=sequence, markup=markup,
                tooltip=tooltip, maximum=maximum)


def monitor_stream(demo=False):
    previous_cpu = cpu_counters(Path("/proc/stat").read_text())
    previous_net = network_counters()
    last = [time.monotonic()] * 3
    sequences = [0, 0, 0]
    graphs = [None, None, None]
    tick = 0
    while True:
        now = time.monotonic()
        if demo or graphs[0] is None or now - last[0] >= 1.5:
            current = cpu_counters(Path("/proc/stat").read_text())
            values = cpu_usage(previous_cpu, current)
            if demo:
                values = [12 + 8 * math.sin(tick / 9), 5, 0, 1, 0]
            percent = round(sum(values))
            graphs[0] = monitor(values, CPU_COLORS, sequences[0],
                                f'{percent}<span size="62.5%" alpha="65%">%</span>',
                                f"CPU: {percent}%")
            previous_cpu, last[0] = current, now
            sequences[0] += 1
        if demo or graphs[1] is None or now - last[1] >= 5:
            values, used, total = memory_usage(Path("/proc/meminfo").read_text())
            if demo:
                values, used, total = [24 + 2 * math.sin(tick / 18), 1, 32], 7.65, 31.0
            graphs[1] = monitor(values, MEMORY_COLORS, sequences[1],
                                f'{used:.3g} / {total:.3g}<span size="62.5%" alpha="65%"> GiB</span>',
                                f"Memory: {values[0]:.0f}% programs, {values[1]:.0f}% buffers, {values[2]:.0f}% cache")
            last[1] = now
            sequences[1] += 1
        if demo or graphs[2] is None or now - last[2] >= 1:
            current = network_counters()
            elapsed = max(0.001, now - last[2])
            down, up = [max(0, new - old) / elapsed for old, new in zip(previous_net, current)]
            if demo:
                down, up = 12000 + 8000 * math.sin(tick / 8), 3000 + 1500 * math.sin(tick / 5)
            graphs[2] = monitor([down, 0, up, 0, 0], NETWORK_COLORS, sequences[2],
                                rate_text(down) + "\n" + rate_text(up),
                                f"Download: {down / 1024:.1f} KiB/s\nUpload: {up / 1024:.1f} KiB/s", maximum=0)
            previous_net, last[2] = current, now
            sequences[2] += 1
        yield {"monitors": graphs}
        tick += 1
        time.sleep(0.02 if demo else 0.5)


def wireless_icon():
    # NetworkManager's cached strength matches the GNOME indicator and works
    # when the driver does not populate the legacy /proc/net/wireless file.
    for line in command("nmcli", "-t", "-f", "IN-USE,SIGNAL", "device", "wifi", "list", "--rescan", "no").splitlines():
        if line.startswith("*:"):
            try:
                quality = int(line.split(":", 1)[1]) / 100
            except ValueError:
                continue
            level = "excellent" if quality >= .8 else "good" if quality >= .55 else "ok" if quality >= .3 else "weak"
            return f"network-wireless-signal-{level}-symbolic", f"Wi-Fi: {round(quality * 100)}%"
    try:
        for line in Path("/proc/net/wireless").read_text().splitlines()[2:]:
            name, values = line.split(":", 1)
            quality = float(values.split()[1]) / 70
            if (Path("/sys/class/net") / name.strip() / "operstate").read_text().strip() != "up":
                continue
            level = "excellent" if quality >= .8 else "good" if quality >= .55 else "ok" if quality >= .3 else "weak"
            return f"network-wireless-signal-{level}-symbolic", f"Wi-Fi: {min(100, round(quality * 100))}%"
        for interface in Path("/sys/class/net").iterdir():
            if (interface / "device").exists() and (interface / "operstate").read_text().strip() == "up":
                if (interface / "wireless").exists() or (interface / "phy80211").exists():
                    return "network-wireless-connected-symbolic", "Wi-Fi connected"
                return "network-wired-symbolic", "Wired network"
    except (OSError, ValueError, IndexError):
        pass
    return "network-wireless-offline-symbolic", "Network disconnected"


def battery_info(contents):
    fields = dict(re.findall(r"^\s*([a-z][a-z -]+):\s*(.*?)\s*$", contents, re.MULTILINE))
    # UPower still returns legacy names such as battery-full-charged-symbolic.
    # GNOME derives Adwaita's current level icons from percentage and state.
    icon = "battery-missing-symbolic"
    try:
        percentage = float(fields.get("percentage", "").rstrip("%"))
        if math.isfinite(percentage):
            level = int(max(0, min(100, percentage)) // 10) * 10
            state = fields.get("state", "unknown")
            if state == "fully-charged" or (state == "charging" and level == 100):
                icon = "battery-level-100-charged-symbolic"
            else:
                suffix = "-charging" if state == "charging" else ""
                if state == "pending-charge" and fields.get("charge-threshold-enabled") == "yes":
                    suffix = "-plugged-in"
                icon = f"battery-level-{level}{suffix}-symbolic"
    except ValueError:
        pass
    duration = fields.get("time to empty") or fields.get("time to full")
    label = ""
    if duration:
        match = re.match(r"([\d.]+)\s+(hours?|minutes?)", duration)
        if match:
            minutes = round(float(match[1]) * (60 if match[2].startswith("hour") else 1))
            label = f"{minutes // 60}∶{minutes % 60:02d}"
    return icon, label, f"Battery: {fields.get('percentage', '—')} · {fields.get('state', 'unknown')}"


def status_items(demo=False):
    if demo:
        return [
            {"icon": "network-wireless-signal-excellent-symbolic", "tooltip": "Wi-Fi"},
            {"icon": "bluetooth-active-symbolic", "tooltip": "Bluetooth"},
            {"icon": "audio-volume-high-symbolic", "tooltip": "Volume"},
            {"icon": "battery-level-80-symbolic", "text": "5∶42", "tooltip": "Battery"},
        ]
    icon, tip = wireless_icon()
    items = [dict(icon=icon, tooltip=tip, command="ghostty -e nmtui")]
    powered = any(
        (entry / "type").read_text().strip() == "bluetooth"
        and (entry / "state").read_text().strip() == "1"
        for entry in Path("/sys/class/rfkill").glob("rfkill*")
        if (entry / "type").exists() and (entry / "state").exists()
    )
    if powered:
        items.append(dict(icon="bluetooth-active-symbolic", tooltip="Bluetooth", command="ghostty -e bluetoothctl"))
    volume = command("wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@")
    match = re.search(r"Volume:\s*([\d.]+)", volume)
    percentage = float(match[1]) * 100 if match else 0
    level = "muted" if "MUTED" in volume or not match else "high" if percentage >= 66 else "medium" if percentage >= 33 else "low"
    items.append(dict(icon=f"audio-volume-{level}-symbolic", tooltip=f"Volume: {percentage:.0f}%", command="pavucontrol"))
    contents = command("upower", "-i", "/org/freedesktop/UPower/devices/DisplayDevice")
    if "is-present:          yes" in contents or "percentage:" in contents:
        icon, label, tip = battery_info(contents)
        items.append(dict(icon=icon, text=label, tooltip=tip, command="ghostty -e sh -c 'upower -d; read -r _'"))
    return items


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=["monitors", "status", "codex", "disk"])
    parser.add_argument("--codex-command")
    parser.add_argument("--codex-icon")
    args = parser.parse_args()
    demo = os.environ.get("WB_PANEL_DEMO") == "1"
    if args.kind == "monitors":
        for data in monitor_stream(demo):
            print(json.dumps(data), flush=True)
        return
    while True:
        if args.kind == "disk":
            rows = command("df", "-h", "/").splitlines()
            fields = rows[1].split() if len(rows) > 1 else []
            label = f"{fields[2]}/{fields[1]}" if len(fields) >= 3 else "—"
            data = {"items": [dict(text=label, tooltip="Root filesystem usage", command="ghostty -e gdu /")]}
        elif args.kind == "status":
            data = {"items": status_items(demo)}
        else:
            try:
                result = json.loads(command(args.codex_command, "--remaining", "--compact", timeout=12)) if not demo else {"text": "54%", "tooltip": "5h: 54% remaining\n7d: 93% remaining"}
            except ValueError:
                result = {"text": "—", "tooltip": "Codex usage unavailable"}
            data = {"items": [dict(icon=args.codex_icon or "", text=result.get("text", "—"))],
                    "tooltip": result.get("tooltip", "")}
        print(json.dumps(data), flush=True)
        time.sleep(60 if args.kind == "codex" else 5)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass
