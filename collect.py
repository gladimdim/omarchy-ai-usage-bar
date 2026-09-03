#!/usr/bin/env python3
"""
AI Usage Bar - Collector Engine
Discovers all installed AI providers on Omarchy and extracts quota/rate limit information.
"""

import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

USAGE_DIR = Path(os.path.expanduser("~/.local/state/omarchy/agents/usage"))
CONFIG_DIR = Path(os.path.expanduser("~/.config/omarchy"))

PROVIDER_COLORS = {
    "claude": "#D97757",
    "grok": "#38BDF8",
    "antigravity": "#A855F7",
    "codex": "#10B981",
    "fireworks": "#F59E0B",
    "opencode": "#EC4899",
    "gemini": "#4285F4",
}

PROVIDER_SHORT_NAMES = {
    "claude": "Claude",
    "grok": "Grok",
    "antigravity": "AGY",
    "codex": "Codex",
    "fireworks": "Firewks",
    "opencode": "OpenCd",
    "gemini": "Gemini",
}


def slugify(text: str) -> str:
    s = re.sub(r"[^\w\s-]", "", text).strip().lower()
    return re.sub(r"[-\s]+", "-", s)


def format_relative_time(resets_at_str: Optional[str]) -> tuple[str, str]:
    if not resets_at_str:
        return ("", "")
    try:
        clean_str = resets_at_str.replace("Z", "+00:00")
        target_dt = dt.datetime.fromisoformat(clean_str)
        now_dt = dt.datetime.now(dt.timezone.utc)
        diff = target_dt - now_dt
        total_seconds = int(diff.total_seconds())

        if total_seconds <= 0:
            return ("resets soon", "now")

        days = total_seconds // 86400
        hours = (total_seconds % 86400) // 3600
        minutes = (total_seconds % 3600) // 60

        if days > 0:
            long_fmt = f"resets in {days}d {hours}h"
            short_fmt = f"{days}d{hours}h" if hours > 0 else f"{days}d"
        elif hours > 0:
            long_fmt = f"resets in {hours}h {minutes}m"
            short_fmt = f"{hours}h{minutes:02d}m" if minutes > 0 else f"{hours}h"
        else:
            long_fmt = f"resets in {minutes}m"
            short_fmt = f"{minutes}m"

        return (long_fmt, short_fmt)
    except Exception:
        return ("", "")


def make_short_label(provider_id: str, limit_title: str) -> str:
    p_short = PROVIDER_SHORT_NAMES.get(provider_id, provider_id.capitalize())
    t_lower = limit_title.lower()

    if "session" in t_lower or "5-hour" in t_lower or "5h" in t_lower:
        return f"{p_short} 5h"
    if "weekly" in t_lower or "7-day" in t_lower:
        return f"{p_short} Wk"
    if "thinking" in t_lower:
        return "AGY Think"
    if "flash" in t_lower:
        return "AGY Flash"
    if "build" in t_lower:
        return f"{p_short} Bld"
    if "chat" in t_lower:
        return f"{p_short} Chat"
    if "task" in t_lower:
        return f"{p_short} Task"
    if "fable" in t_lower:
        return f"{p_short} Fbl"

    words = limit_title.split()
    if words:
        return f"{p_short} {words[0][:4]}"
    return p_short


def format_tokens(count: Optional[int]) -> str:
    if not count:
        return "0"
    if count >= 1_000_000_000:
        return f"{count / 1_000_000_000:.1f}B"
    if count >= 1_000_000:
        return f"{count / 1_000_000:.1f}M"
    if count >= 1_000:
        return f"{count / 1_000:.1f}k"
    return str(count)


def format_relative_past(iso_str: Optional[str]) -> str:
    if not iso_str:
        return ""
    try:
        clean_str = iso_str.replace("Z", "+00:00")
        target_dt = dt.datetime.fromisoformat(clean_str)
        now_dt = dt.datetime.now(dt.timezone.utc)
        diff = now_dt - target_dt
        secs = int(diff.total_seconds())
        if secs < 60:
            return "just now"
        mins = secs // 60
        if mins < 60:
            return f"{mins}m ago"
        hours = mins // 60
        if hours < 24:
            return f"{hours}h ago"
        days = hours // 24
        return f"{days}d ago"
    except Exception:
        return ""


def generate_ascii_bar(percent: float, length: int = 16, style: str = "blocks") -> str:
    clamped = max(0.0, min(1.0, percent))
    fill_count = int(round(clamped * length))
    empty_count = length - fill_count

    if style == "subblocks":
        eighths = int(round(clamped * length * 8))
        full = eighths // 8
        rem = eighths % 8
        partials = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
        p_char = partials[rem] if (rem > 0 and full < length) else ""
        empty = max(0, length - full - (1 if p_char else 0))
        return "[" + ("█" * full) + p_char + ("░" * empty) + "]"

    elif style == "dots":
        return "[" + ("●" * fill_count) + ("○" * empty_count) + "]"

    elif style == "pipes":
        return "[" + ("|" * fill_count) + ("." * empty_count) + "]"

    elif style == "ascii":
        if fill_count == 0:
            body = " " * length
        elif fill_count == length:
            body = "=" * length
        else:
            body = "=" * (fill_count - 1) + ">" + " " * empty_count
        return f"[{body}]"

    elif style == "retro":
        return "[" + ("#" * fill_count) + ("-" * empty_count) + "]"

    elif style == "squares":
        return "[" + ("■" * fill_count) + ("□" * empty_count) + "]"

    elif style == "shaded":
        return "[" + ("▓" * fill_count) + ("░" * empty_count) + "]"

    elif style == "braille":
        return "[" + ("⣿" * fill_count) + ("⣀" * empty_count) + "]"

    else:  # blocks (default)
        return "[" + ("█" * fill_count) + ("░" * empty_count) + "]"


def ensure_antigravity_data() -> None:
    """Run antigravity scanner if available to make sure antigravity.json is present and fresh."""
    scanner_paths = [
        os.path.expanduser("~/.config/omarchy/plugins/jesseburlamaque.antigravity-usage/scripts/antigravity_usage_scanner.py"),
        os.path.expanduser("~/.config/omarchy/plugins/jesseburlamaque.antigravity-usage/bin/omarchy-agent-usage-antigravity"),
    ]
    
    for sp in scanner_paths:
        if os.path.exists(sp):
            try:
                cmd = ["python3", sp] if sp.endswith(".py") else [sp]
                res = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
                if res.returncode == 0 and res.stdout.strip():
                    data = json.loads(res.stdout)
                    if data.get("schemaVersion") or "limits" in data:
                        USAGE_DIR.mkdir(parents=True, exist_ok=True)
                        dest = USAGE_DIR / "antigravity.json"
                        tmp_dest = USAGE_DIR / ".antigravity.json.tmp"
                        with open(tmp_dest, "w", encoding="utf-8") as f:
                            json.dump(data, f, indent=2)
                        os.replace(tmp_dest, dest)
                        break
            except Exception:
                pass


def refresh_omarchy_agents() -> None:
    """Trigger Omarchy agent usage update."""
    update_scripts = [
        os.path.expanduser("~/.config/omarchy/agents/update"),
        "/usr/share/omarchy/bin/omarchy-agent-usage-update",
    ]
    for script in update_scripts:
        if os.path.exists(script) and os.access(script, os.X_OK):
            try:
                subprocess.run([script, "--force"], capture_output=True, timeout=10)
                break
            except Exception:
                pass
    ensure_antigravity_data()


def collect_all_data() -> Dict[str, Any]:
    ensure_antigravity_data()

    providers: List[Dict[str, Any]] = []
    all_limits: List[Dict[str, Any]] = []

    if not USAGE_DIR.exists():
        USAGE_DIR.mkdir(parents=True, exist_ok=True)

    json_files = sorted(glob.glob(str(USAGE_DIR / "*.json")))

    for fpath in json_files:
        try:
            with open(fpath, "r", encoding="utf-8") as fp:
                data = json.load(fp)
        except Exception:
            continue

        prov_id = data.get("id") or Path(fpath).stem
        prov_name = data.get("name") or prov_id.capitalize()
        tier_label = data.get("tierLabel", "")
        prov_color = PROVIDER_COLORS.get(prov_id, "#38BDF8")
        ready = data.get("ready", True)
        status_text = data.get("usageStatusText", "")
        auth_help = data.get("authHelpText", "")

        raw_limits = data.get("limits", [])
        parsed_limits: List[Dict[str, Any]] = []

        for idx, lim in enumerate(raw_limits):
            title = lim.get("title") or lim.get("label") or f"Limit {idx + 1}"
            limit_slug = slugify(title)
            unique_id = f"{prov_id}:{limit_slug}"

            percent = float(lim.get("percent", 0.0))
            resets_at = lim.get("resetsAt", "")
            resets_long, resets_short = format_relative_time(resets_at)

            short_label = make_short_label(prov_id, title)
            limit_color = lim.get("color") or prov_color

            used = lim.get("used")
            allowance = lim.get("allowance")

            lim_obj = {
                "id": unique_id,
                "providerId": prov_id,
                "providerName": prov_name,
                "title": title,
                "shortLabel": short_label,
                "percent": percent,
                "percentInt": int(round(percent * 100)),
                "resetsAt": resets_at,
                "resetsFormatted": resets_long,
                "resetsShort": resets_short,
                "used": used,
                "allowance": allowance,
                "color": limit_color,
                "asciiBlocks": generate_ascii_bar(percent, 16, "blocks"),
                "asciiClassic": generate_ascii_bar(percent, 16, "ascii"),
                "asciiRetro": generate_ascii_bar(percent, 16, "retro"),
            }
            parsed_limits.append(lim_obj)
            all_limits.append(lim_obj)

        provider_obj = {
            "id": prov_id,
            "name": prov_name,
            "shortName": PROVIDER_SHORT_NAMES.get(prov_id, prov_name[:7]),
            "tierLabel": tier_label,
            "color": prov_color,
            "ready": ready,
            "statusText": status_text,
            "authHelpText": auth_help,
            "limitsCount": len(parsed_limits),
            "limits": parsed_limits,
            "todayPrompts": data.get("todayPrompts", 0),
            "todaySessions": data.get("todaySessions", 0),
            "todayTotalTokens": data.get("todayTotalTokens", 0),
            "todayTokensFormatted": format_tokens(data.get("todayTotalTokens", 0)),
            "updatedAt": data.get("updatedAt", ""),
            "updatedAgo": format_relative_past(data.get("updatedAt", "")),
        }
        providers.append(provider_obj)

    all_limits.sort(key=lambda l: (l["providerId"] not in ("claude", "grok", "antigravity"), -l["percent"]))

    return {
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "providersCount": len(providers),
        "limitsCount": len(all_limits),
        "providers": providers,
        "allLimits": all_limits,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="AI Usage Bar Collector")
    parser.add_argument("--refresh", action="store_true", help="Force update before collecting")
    parser.add_argument("--json", action="store_true", default=True, help="Emit JSON output")
    args = parser.parse_args()

    if args.refresh:
        refresh_omarchy_agents()

    result = collect_all_data()
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
