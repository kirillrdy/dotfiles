import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


panel = load("panel", "waybar-panel.py")
codex = load("codex", "waybar-codex.py")


class MonitorTests(unittest.TestCase):
    @patch.object(panel, "command", return_value="*:72\n:50")
    def test_wifi_uses_networkmanager_cached_strength(self, command):
        icon, tooltip = panel.wireless_icon()
        self.assertEqual(icon, "network-wireless-signal-good-symbolic")
        self.assertEqual(tooltip, "Wi-Fi: 72%")
        self.assertIn("--rescan", command.call_args.args)
        self.assertEqual(command.call_args.args[-1], "no")

    def test_cpu_categories_share_one_total(self):
        values = panel.cpu_usage([0] * 8, [20, 5, 10, 50, 5, 3, 4, 3])
        self.assertEqual(values, [20, 10, 5, 5, 10])
        self.assertEqual(sum(values), 50)

    def test_cpu_counter_reset_and_idle_samples(self):
        self.assertEqual(panel.cpu_usage([100] * 8, [0] * 8), [0] * 5)
        self.assertEqual(panel.cpu_usage([0] * 8, [0, 0, 0, 100, 0, 0, 0, 0]), [0] * 5)

    def test_memory_graph_separates_programs_buffers_and_cache(self):
        values, used, total = panel.memory_usage(
            "MemTotal: 1048576 kB\nMemFree: 262144 kB\nBuffers: 131072 kB\n"
            "Cached: 262144 kB\nSReclaimable: 131072 kB\nShmem: 131072 kB\n"
        )
        self.assertEqual(values, [37.5, 12.5, 25])
        self.assertEqual((used, total), (.375, 1))

    def test_memory_zero_total_is_safe(self):
        values, _, total = panel.memory_usage("MemTotal: 0 kB\nMemFree: 0 kB\n")
        self.assertTrue(all(value >= 0 for value in values))
        self.assertGreater(total, 0)

    def test_network_unit_boundaries(self):
        self.assertIn("KiB/s", panel.rate_text(1024))
        self.assertIn("MiB/s", panel.rate_text(1024 ** 2))
        self.assertIn("GiB/s", panel.rate_text(1024 ** 3))
        self.assertTrue(panel.rate_text(-1).startswith("0"))

    def test_battery_remaining_time_matches_extension(self):
        icon, label, tooltip = panel.battery_info(
            "    state: discharging\n    percentage: 80%\n"
            "    time to empty: 2.5 hours\n    icon-name: 'battery-level-80-symbolic'\n"
        )
        self.assertEqual(icon, "battery-level-80-symbolic")
        self.assertEqual(label, "2∶30")
        self.assertIn("80%", tooltip)

    def test_charged_battery_hides_unknown_estimate(self):
        self.assertEqual(panel.battery_info("state: fully-charged\npercentage: 100%\n")[1], "")

    def test_legacy_upower_battery_names_use_current_adwaita_icons(self):
        cases = [
            ("state: fully-charged\npercentage: 100%\nicon-name: 'battery-full-charged-symbolic'\n",
             "battery-level-100-charged-symbolic"),
            ("state: charging\npercentage: 85%\nicon-name: 'battery-good-charging-symbolic'\n",
             "battery-level-80-charging-symbolic"),
            ("state: charging\npercentage: 100%\n", "battery-level-100-charged-symbolic"),
            ("state: discharging\npercentage: 87%\n", "battery-level-80-symbolic"),
            ("state: pending-charge\npercentage: 80%\ncharge-threshold-enabled: yes\n",
             "battery-level-80-plugged-in-symbolic"),
        ]
        for contents, expected in cases:
            with self.subTest(contents=contents):
                self.assertEqual(panel.battery_info(contents)[0], expected)

    def test_invalid_battery_percentage_uses_missing_icon(self):
        for value in ("unknown", "nan", "inf", ""):
            self.assertEqual(panel.battery_info(f"percentage: {value}\n")[0],
                             "battery-missing-symbolic")


class CodexDisplayTests(unittest.TestCase):
    def test_compact_cli_without_login_is_a_single_placeholder(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, str(Path(codex.__file__)), "--remaining", "--compact"],
                env={**os.environ, "CODEX_HOME": directory},
                capture_output=True, text=True, check=True,
            )
        self.assertEqual(json.loads(result.stdout)["text"], "—")

    def test_gnome_shows_primary_remaining_allowance(self):
        result = codex.format_usage({"rate_limit": {
            "primary_window": {"used_percent": 46},
            "secondary_window": {"used_percent": 7},
        }}, remaining=True, compact=True)
        self.assertEqual(result["text"], "54%")
        self.assertIn("7d: 93% remaining", result["tooltip"])

    def test_original_format_still_works(self):
        result = codex.format_usage({"rate_limit": {
            "primary_window": {"used_percent": 46},
            "secondary_window": {"used_percent": 7},
        }})
        self.assertEqual(result["text"], "Codex 5h 46% · 7d 7%")

    def test_missing_primary_does_not_misreport_weekly_as_primary(self):
        result = codex.format_usage({"rate_limit": {
            "secondary_window": {"used_percent": 7},
        }}, remaining=True, compact=True)
        self.assertEqual(result["text"], "—")

    def test_invalid_values_do_not_display_fake_allowance(self):
        for value in (None, True, "50", float("nan"), float("inf")):
            result = codex.format_usage({"rate_limit": {
                "primary_window": {"used_percent": value},
            }}, remaining=True, compact=True)
            self.assertEqual(result["class"], "unavailable")


if __name__ == "__main__":
    unittest.main()
