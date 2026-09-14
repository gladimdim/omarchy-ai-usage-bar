"""Collector checks against fixture files in temporary directories.

Run with: python3 -m unittest discover -s tests
"""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("collect", Path(__file__).parent.parent / "collect.py")
collect = importlib.util.module_from_spec(spec)
sys.modules["collect"] = collect
spec.loader.exec_module(collect)

NOW = dt.datetime.now(dt.timezone.utc)


def iso(moment):
    return moment.isoformat()


def billing_line(percent, start, end, tier="SuperGrok"):
    return json.dumps({
        "ts": iso(NOW - dt.timedelta(minutes=5)).replace("+00:00", "Z"),
        "src": "shell", "lvl": "info", "msg": collect.GROK_BILLING_MSG,
        "ctx": {
            "config": {
                "creditUsagePercent": percent,
                "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": iso(start), "end": iso(end)},
                "onDemandCap": {"val": 0},
                "billingPeriodStart": iso(start),
                "billingPeriodEnd": iso(end),
            },
            "onDemandEnabled": None,
            "subscriptionTier": tier,
        },
    })


class GrokCollectorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ai-usage-collect-")
        root = Path(self.tmp.name)
        self.saved = (collect.GROK_HOME, collect.USAGE_DIR, collect.GROK_LOG_BLOCK_BYTES)
        collect.GROK_HOME = root / "grok"
        collect.USAGE_DIR = root / "usage"
        collect.USAGE_DIR.mkdir(parents=True)
        self.log = collect.GROK_HOME / "logs" / "unified.jsonl"
        self.log.parent.mkdir(parents=True)

    def tearDown(self):
        collect.GROK_HOME, collect.USAGE_DIR, collect.GROK_LOG_BLOCK_BYTES = self.saved
        self.tmp.cleanup()

    def write_log(self, *lines):
        self.log.write_text("".join(line + "\n" for line in lines))

    def grok_limits(self):
        return [l for l in collect.collect_all_data()["allLimits"] if l["providerId"] == "grok"]

    def test_reads_newest_allowance_as_weekly_limit(self):
        start, end = NOW - dt.timedelta(days=2), NOW + dt.timedelta(days=5)
        noise = json.dumps({"ts": iso(NOW), "msg": "turn finished", "ctx": {}})
        # A tiny block size makes the reverse scan cross line boundaries.
        collect.GROK_LOG_BLOCK_BYTES = 37
        self.write_log(billing_line(12.0, start, end), noise, "{not json", billing_line(27.0, start, end), noise)

        data = collect.collect_all_data()
        grok = next(p for p in data["providers"] if p["id"] == "grok")
        self.assertEqual(grok["tierLabel"], "SuperGrok")
        [limit] = grok["limits"]
        self.assertEqual(limit["id"], "grok:weekly")
        self.assertEqual(limit["shortLabel"], "Grok Wk")
        self.assertAlmostEqual(limit["percent"], 0.27)
        self.assertEqual(limit["resetsAt"], iso(end))

    def test_rolled_over_window_resets_to_zero(self):
        start, end = NOW - dt.timedelta(days=9), NOW - dt.timedelta(days=2)
        self.write_log(billing_line(61.0, start, end))

        [limit] = self.grok_limits()
        self.assertEqual(limit["percent"], 0.0)
        self.assertEqual(limit["resetsAt"], iso(end + dt.timedelta(days=7)))

    def test_omarchy_grok_record_takes_precedence(self):
        self.write_log(billing_line(27.0, NOW, NOW + dt.timedelta(days=7)))
        (collect.USAGE_DIR / "grok.json").write_text(json.dumps(
            {"id": "grok", "name": "Grok", "limits": [{"label": "Weekly", "percent": 0.5}]}))

        [limit] = self.grok_limits()
        self.assertEqual(limit["percent"], 0.5)

    def test_missing_or_unrelated_log_hides_grok(self):
        self.assertEqual(self.grok_limits(), [])
        self.write_log(json.dumps({"msg": "startup", "ctx": {"creditUsagePercent": "?"}}))
        self.assertEqual(self.grok_limits(), [])

    def test_non_object_lines_are_skipped(self):
        start, end = NOW - dt.timedelta(days=1), NOW + dt.timedelta(days=6)
        self.write_log(billing_line(40.0, start, end), json.dumps("creditUsagePercent"), '["creditUsagePercent"]')

        [limit] = self.grok_limits()
        self.assertAlmostEqual(limit["percent"], 0.4)

    def test_non_finite_percent_hides_grok(self):
        start, end = NOW - dt.timedelta(days=1), NOW + dt.timedelta(days=6)
        for value in ("NaN", "Infinity"):
            self.write_log(billing_line(1.0, start, end).replace('"creditUsagePercent": 1.0', f'"creditUsagePercent": {value}'))
            self.assertEqual(self.grok_limits(), [])

    def test_degenerate_period_rolls_over_without_looping(self):
        end = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)
        self.write_log(billing_line(50.0, end - dt.timedelta(microseconds=1), end))

        [limit] = self.grok_limits()
        resets = dt.datetime.fromisoformat(limit["resetsAt"])
        self.assertEqual(limit["percent"], 0.0)
        self.assertTrue(NOW < resets <= NOW + dt.timedelta(days=7))

    def test_grok_failure_keeps_other_providers(self):
        (collect.USAGE_DIR / "claude.json").write_text(json.dumps(
            {"id": "claude", "limits": [{"label": "Session (5-hour)", "percent": 0.1}]}))
        (collect.USAGE_DIR / "broken.json").write_text("[1, 2]")
        saved = collect.grok_usage_record

        def explode(now=None):
            raise RuntimeError("unexpected log shape")

        collect.grok_usage_record = explode
        try:
            data = collect.collect_all_data()
        finally:
            collect.grok_usage_record = saved
        self.assertEqual([p["id"] for p in data["providers"]], ["claude"])


if __name__ == "__main__":
    unittest.main()
