"""Display Codex account limits in Waybar, using the existing Codex login."""

import argparse
import json
import math
import os
from datetime import datetime
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def unavailable(message):
    return {"text": "Codex —", "tooltip": message, "class": "unavailable"}


def format_usage(data, remaining=False, compact=False):
    limits = data.get("rate_limit")
    if not isinstance(limits, dict):
        return unavailable("Codex usage is unavailable")

    labels = []
    tooltip = ["Codex allowance remaining" if remaining else "Codex allowance used"]
    percentages = []
    primary_display = None
    for key, label in (("primary_window", "5h"), ("secondary_window", "7d")):
        window = limits.get(key) or {}
        percent = window.get("used_percent")
        if (
            isinstance(percent, bool)
            or not isinstance(percent, (int, float))
            or not math.isfinite(percent)
        ):
            labels.append(f"{label} —")
            continue
        percent = max(0, min(100, percent))
        percentages.append(percent)
        display = 100 - percent if remaining else percent
        if key == "primary_window":
            primary_display = display
        labels.append(f"{label} {display:.0f}%")
        detail = f"{label}: {display:.0f}% {'remaining' if remaining else 'used'}"
        reset = window.get("reset_at")
        if isinstance(reset, (int, float)) and not isinstance(reset, bool):
            try:
                detail += datetime.fromtimestamp(reset).strftime(", resets %a %H:%M")
            except (ValueError, OverflowError, OSError):
                pass
        tooltip.append(detail)

    if not percentages:
        return unavailable("Codex usage is unavailable")
    highest = max(percentages)
    level = "critical" if highest >= 90 else "warning" if highest >= 75 else "normal"
    return {
        "text": (f"{primary_display:.0f}%" if primary_display is not None else "—")
        if compact else "Codex " + " · ".join(labels),
        "tooltip": "\n".join(tooltip),
        "class": level,
        "percentage": round(highest),
    }


def read_usage(remaining=False, compact=False):
    codex_dir = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    try:
        auth = json.loads((codex_dir / "auth.json").read_text())
        tokens = auth.get("tokens") or auth
        token = tokens.get("access_token")
        if not token:
            return unavailable("Sign in with codex login to see account usage")
        headers = {"Authorization": f"Bearer {token}", "User-Agent": "codex-cli"}
        if tokens.get("account_id"):
            headers["ChatGPT-Account-Id"] = tokens["account_id"]
        request = Request("https://chatgpt.com/backend-api/wham/usage", headers=headers)
        with urlopen(request, timeout=10) as response:
            return format_usage(json.load(response), remaining=remaining, compact=compact)
    except HTTPError as error:
        if error.code in (401, 403):
            return unavailable("Codex login needs refreshing; run codex login")
        return unavailable(f"Codex usage service returned HTTP {error.code}")
    except (OSError, URLError, ValueError, TypeError, AttributeError):
        # Never log authentication data or request headers.
        return unavailable("Codex usage is unavailable; check login and network")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--remaining", action="store_true")
    parser.add_argument("--compact", action="store_true")
    args = parser.parse_args()
    result = read_usage(args.remaining, args.compact)
    if args.compact and result.get("class") == "unavailable":
        result["text"] = "—"
    print(json.dumps(result, ensure_ascii=False))
