"""Display Codex account limits in Waybar, using the existing Codex login."""

import json
import math
import os
from datetime import datetime
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def unavailable(message):
    return {"text": "Codex —", "tooltip": message, "class": "unavailable"}


def format_usage(data):
    limits = data.get("rate_limit")
    if not isinstance(limits, dict):
        return unavailable("Codex usage is unavailable")

    labels = []
    tooltip = ["Codex allowance used"]
    percentages = []
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
        labels.append(f"{label} {percent:.0f}%")
        detail = f"{label}: {percent:.0f}% used"
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
        "text": "Codex " + " · ".join(labels),
        "tooltip": "\n".join(tooltip),
        "class": level,
        "percentage": round(highest),
    }


def read_usage():
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
            return format_usage(json.load(response))
    except HTTPError as error:
        if error.code in (401, 403):
            return unavailable("Codex login needs refreshing; run codex login")
        return unavailable(f"Codex usage service returned HTTP {error.code}")
    except (OSError, URLError, ValueError, TypeError, AttributeError):
        # Never log authentication data or request headers.
        return unavailable("Codex usage is unavailable; check login and network")


if __name__ == "__main__":
    print(json.dumps(read_usage(), ensure_ascii=False))
