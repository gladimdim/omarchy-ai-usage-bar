#!/usr/bin/env python3
"""
AI Usage Bar - Collector Engine
Discovers all installed AI providers on Omarchy and extracts quota/rate limit information.
"""

import argparse
import datetime as dt
import glob
import json
import math
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
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
    "opencode-go": "#EC4899",
    "commandcode": "#F97316",
    "gemini": "#4285F4",
}

PROVIDER_SHORT_NAMES = {
    "claude": "Claude",
    "grok": "Grok",
    "antigravity": "AGY",
    "codex": "Codex",
    "fireworks": "Firewks",
    "opencode": "OpenCd",
    "opencode-go": "OC Go",
    "commandcode": "CmdCd",
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


# --------------------------------------------------------------------------- #
# Subscription providers (OpenCode Go, Command Code)
#
# Omarchy's own agent integrations do not cover these two, so nothing ever
# writes their usage JSON into USAGE_DIR. These fetchers fill that gap the
# same way ensure_antigravity_data() fills Antigravity's: produce the exact
# file shape the collector below already parses, then let the normal
# discovery loop render it. Standard library only; the endpoints are fixed
# and the Authorization header is never forwarded off-origin.
# --------------------------------------------------------------------------- #

OPENCODE_USAGE_URL = "https://opencode.ai/zen/go/v1/usage"
COMMANDCODE_CREDITS_URL = "https://api.commandcode.ai/alpha/billing/credits"

SUBSCRIPTION_TIMEOUT_S = 8
MAX_RESPONSE_BYTES = 4096
SUBSCRIPTION_USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) omarchy-ai-usage-bar"
SUBSCRIPTION_ENV_FILE = Path(os.path.expanduser("~/.config/omarchy/ai-limits.env"))
SUBSCRIPTION_KEY_VARS = ("OPENCODE_GO_API_KEY", "OPENCODE_ZEN_API_KEY", "COMMANDCODE_API_KEY")

_opencode_windows = (
    ("rolling", "5h"),
    ("weekly", "Weekly"),
    ("monthly", "Monthly"),
)


class _SameOriginRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Follow redirects only within the same origin (scheme + host) so the
    Authorization (API key) header is never forwarded elsewhere and never
    downgraded to plaintext. Any other redirect raises HTTPError."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = urllib.parse.urlparse(newurl)
        old = urllib.parse.urlparse(req.full_url)
        if (new.scheme, new.netloc) != (old.scheme, old.netloc):
            raise urllib.error.HTTPError(
                req.full_url, code, "cross-origin redirect refused", headers, fp
            )
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_SUBSCRIPTION_OPENER = urllib.request.build_opener(
    _SameOriginRedirectHandler(),
    urllib.request.HTTPSHandler(context=ssl.create_default_context()),
)


def _load_subscription_env_file() -> None:
    """Load KEY=VALUE pairs from SUBSCRIPTION_ENV_FILE into os.environ (once).

    Only the keys this plugin understands are accepted; unknown lines are
    ignored. Values are taken verbatim (optional ``export`` prefix, surrounding
    single/double quotes and trailing comments stripped) — no interpolation,
    so nothing in the file is ever executed.
    """
    path = SUBSCRIPTION_ENV_FILE
    try:
        if not path.is_file():
            return
        with open(path, "r", encoding="utf-8") as fh:
            for raw_line in fh:
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                line = re.sub(r"^export\s+", "", line)
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip()
                if key not in SUBSCRIPTION_KEY_VARS or not value:
                    continue
                if value and value[0] in "\"'":
                    quote = value[0]
                    end = value.find(quote, 1)
                    if end != -1:
                        value = value[1:end]
                os.environ.setdefault(key, value)
    except Exception as exc:
        print(f"ai-usage-bar: could not read {path}: {type(exc).__name__}", file=sys.stderr)


def _read_subscription_key(env_names: tuple) -> Optional[str]:
    for env_name in env_names:
        value = os.environ.get(env_name, "").strip()
        if value:
            return value
    return None


def _subscription_request_json(url: str, api_key: str):
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
            "User-Agent": SUBSCRIPTION_USER_AGENT,
        },
    )
    with _SUBSCRIPTION_OPENER.open(request, timeout=SUBSCRIPTION_TIMEOUT_S) as response:
        raw = response.read(MAX_RESPONSE_BYTES + 1)
        if len(raw) > MAX_RESPONSE_BYTES:
            raise ValueError("response-too-large")
    return json.loads(raw.decode("utf-8", errors="replace"))


def _finite(value: Any, default: float = 0.0) -> float:
    """Reject NaN/inf so json.dumps never emits bare Infinity (invalid JSON)."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return number if math.isfinite(number) else default


def _subscription_transport_error(exc: Exception) -> str:
    if isinstance(exc, urllib.error.HTTPError):
        return f"HTTP {exc.code}"
    if isinstance(exc, (urllib.error.URLError, TimeoutError, OSError)):
        return "network error"
    if isinstance(exc, (json.JSONDecodeError, UnicodeDecodeError, ValueError)):
        return "unexpected response"
    return "unknown error"


def _fetch_opencode_go(api_key: str) -> Dict[str, Any]:
    """OpenCode Go usage: rolling 5h / weekly / monthly percent windows."""
    body = _subscription_request_json(OPENCODE_USAGE_URL, api_key)
    raw_usage = body.get("usage") if isinstance(body, dict) else None
    if not isinstance(raw_usage, dict):
        raise ValueError("unexpected-response")

    limits: List[Dict[str, Any]] = []
    headline: Optional[float] = None
    detail_parts: List[str] = []
    for window_id, title in _opencode_windows:
        window = raw_usage.get(window_id)
        if not isinstance(window, dict) or window.get("percent") is None:
            continue
        percent = _finite(window["percent"])
        resets_at = window.get("resetsAt") if isinstance(window.get("resetsAt"), str) else ""
        if headline is None:
            headline = percent
        detail_parts.append(f"{title} {round(percent)}%")
        limits.append({"title": title, "percent": percent / 100.0, "resetsAt": resets_at})
    if not limits:
        raise ValueError("unexpected-response")

    return {
        "tierLabel": "Subscription",
        "usageStatusText": " · ".join(detail_parts),
        "limits": limits,
        "headline_percent": headline,
    }


def _fetch_command_code(api_key: str) -> Dict[str, Any]:
    """Command Code: 5h/weekly percent windows plus a USD credit balance."""
    body = _subscription_request_json(COMMANDCODE_CREDITS_URL, api_key)
    if not isinstance(body, dict):
        raise ValueError("unexpected-response")
    credits = body.get("credits") if isinstance(body.get("credits"), dict) else None
    window_limits = body.get("windowLimits") if isinstance(body.get("windowLimits"), dict) else None
    if credits is None and window_limits is None:
        raise ValueError("unexpected-response")

    monthly_credits = _finite(credits.get("monthlyCredits")) if credits else 0.0
    purchased = _finite(credits.get("purchasedCredits")) if credits else 0.0
    free = _finite(credits.get("freeCredits")) if credits else 0.0
    # _finite on the sum too: two large-but-finite components can still add
    # up to inf, which would serialize as bare Infinity.
    total_remaining = max(0.0, _finite(monthly_credits + purchased + free))

    limits = []
    detail_parts: List[str] = []
    headline: Optional[float] = None
    for raw_key, title in (("fiveHour", "5h"), ("weekly", "Weekly")):
        window = window_limits.get(raw_key) if isinstance(window_limits, dict) else None
        if not isinstance(window, dict):
            continue
        cap = _finite(window.get("cap"))
        used = _finite(window.get("used"))
        if cap <= 0:
            continue
        percent = round(min(100.0, max(0.0, used / cap * 100.0)), 1)
        # resetAt is epoch ms — convert to the ISO instant the collector expects.
        reset_ms = window.get("resetAt")
        reset_iso = ""
        if isinstance(reset_ms, (int, float)) and reset_ms > 0:
            try:
                reset_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(reset_ms / 1000.0))
            except (ValueError, OverflowError, OSError):
                reset_iso = ""
        if headline is None:
            headline = percent
        detail_parts.append(f"{title} {round(percent)}%")
        limits.append({"title": title, "percent": percent / 100.0, "resetsAt": reset_iso})
    if not limits:
        raise ValueError("unexpected-response")

    if total_remaining > 0:
        detail_parts.append(f"${total_remaining:,.2f} remaining")
    return {
        "tierLabel": f"${total_remaining:,.2f} left" if total_remaining > 0 else "Subscription",
        "usageStatusText": " · ".join(detail_parts),
        "limits": limits,
        "headline_percent": headline,
    }


def _write_usage_file(name: str, payload: Dict[str, Any]) -> None:
    USAGE_DIR.mkdir(parents=True, exist_ok=True)
    dest = USAGE_DIR / f"{name}.json"
    tmp_dest = USAGE_DIR / f".{name}.json.tmp"
    with open(tmp_dest, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
    os.replace(tmp_dest, dest)


def _write_subscription_stub(name: str, display_name: str, auth_help: str) -> None:
    """Write a ready:false file so the UI offers setup help for this provider."""
    _write_usage_file(
        name,
        {
            "id": name,
            "name": display_name,
            "ready": False,
            "hasLocalStats": False,
            "usageStatusText": f"{display_name} not configured",
            "authHelpText": auth_help,
            "limits": [],
            "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        },
    )


def ensure_subscription_data() -> None:
    """Fetch OpenCode Go / Command Code usage into USAGE_DIR.

    Runs on every collector pass. Missing keys produce a ready:false stub so
    the widget can show setup help (same as Omarchy's own providers); fetch
    errors keep the last good file so a flaky network never blanks the bars.
    If Omarchy's own OpenCode integration is active (opencode.json ready),
    OpenCode Go tracking is skipped to avoid showing the provider twice.
    """
    _load_subscription_env_file()

    oc_key = _read_subscription_key(("OPENCODE_GO_API_KEY", "OPENCODE_ZEN_API_KEY"))
    cc_key = _read_subscription_key(("COMMANDCODE_API_KEY",))

    omarchy_opencode_path = USAGE_DIR / "opencode.json"
    if oc_key and omarchy_opencode_path.exists():
        try:
            with open(omarchy_opencode_path, "r", encoding="utf-8") as fh:
                if json.load(fh).get("ready"):
                    oc_key = None
                    _write_usage_file(
                        "opencode-go",
                        {
                            "id": "opencode-go",
                            "name": "OpenCode Go",
                            "ready": True,
                            "hasLocalStats": False,
                            "usageStatusText": "Tracked by Omarchy's OpenCode integration",
                            "limits": [],
                        },
                    )
        except Exception:
            pass

    for name, display_name, api_key, fetch, key_names in (
        (
            "opencode-go",
            "OpenCode Go",
            oc_key,
            _fetch_opencode_go,
            "OPENCODE_GO_API_KEY (or OPENCODE_ZEN_API_KEY)",
        ),
        ("commandcode", "Command Code", cc_key, _fetch_command_code, "COMMANDCODE_API_KEY"),
    ):
        if not api_key:
            if not (USAGE_DIR / f"{name}.json").exists():
                _write_subscription_stub(
                    name, display_name, f"Set {key_names} in your environment or ~/.config/omarchy/ai-limits.env."
                )
            continue
        try:
            result = fetch(api_key)
            _write_usage_file(
                name,
                {
                    "id": name,
                    "name": display_name,
                    "ready": True,
                    "hasLocalStats": False,
                    "tierLabel": result["tierLabel"],
                    "usageStatusText": result["usageStatusText"],
                    "limits": result["limits"],
                    "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
                },
            )
        except Exception as exc:
            print(
                f"ai-usage-bar: {display_name} usage refresh failed ({_subscription_transport_error(exc)}); keeping last good data",
                file=sys.stderr,
            )


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
    ensure_subscription_data()
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
