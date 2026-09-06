"""Hermetic tests for the OpenCode Go / Command Code subscription fetchers.

No network access and no writes outside a temporary directory: the collector
module is loaded from the repo root, its USAGE_DIR is pointed at a tmp dir,
and the HTTP layer is mocked. Run with:

    python3 -m unittest discover -s tests -p 'test_*.py'
"""
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock


def _load_collect():
    root = Path(__file__).resolve().parent.parent
    spec = importlib.util.spec_from_file_location("collect_under_test", root / "collect.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SubscriptionFetcherTests(unittest.TestCase):
    def setUp(self):
        self.m = _load_collect()
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.m.USAGE_DIR = Path(tmp.name)
        self.envfile = Path(tmp.name) / "ai-limits.env"
        self.m.SUBSCRIPTION_ENV_FILE = self.envfile
        # Snapshot the relevant env vars; tests pop them and the patcher
        # restores the original environment on stop.
        patcher = mock.patch.dict(os.environ)
        patcher.start()
        self.addCleanup(patcher.stop)
        for key in self.m.SUBSCRIPTION_KEY_VARS:
            os.environ.pop(key, None)

    # ------------------------------------------------------------------ #
    # Unconfigured / stale-state behavior
    # ------------------------------------------------------------------ #
    def test_stub_written_when_unconfigured(self):
        self.m.ensure_subscription_data()
        for name in ("opencode-go", "commandcode"):
            data = json.loads((self.m.USAGE_DIR / f"{name}.json").read_text())
            self.assertFalse(data["ready"])
            self.assertIn("API_KEY", data["authHelpText"])

    def test_stale_ready_true_corrected_to_stub_after_key_removal(self):
        (self.m.USAGE_DIR / "commandcode.json").write_text(
            json.dumps({"id": "commandcode", "ready": True, "limits": [{"title": "5h", "percent": 0.5}]})
        )
        self.m.ensure_subscription_data()
        data = json.loads((self.m.USAGE_DIR / "commandcode.json").read_text())
        self.assertFalse(data["ready"])
        self.assertEqual(data["limits"], [])

    def test_omarchy_dedupe_marker_when_integration_active(self):
        (self.m.USAGE_DIR / "opencode.json").write_text(json.dumps({"id": "opencode", "ready": True}))
        self.m.ensure_subscription_data()
        data = json.loads((self.m.USAGE_DIR / "opencode-go.json").read_text())
        self.assertTrue(data["ready"])
        self.assertIn("Tracked by Omarchy", data["usageStatusText"])

    def test_live_fetch_skipped_when_omarchy_integration_active(self):
        (self.m.USAGE_DIR / "opencode.json").write_text(json.dumps({"id": "opencode", "ready": True}))
        with mock.patch.object(self.m, "_fetch_opencode_go", side_effect=AssertionError("must not fetch")):
            self.m.ensure_subscription_data()
        data = json.loads((self.m.USAGE_DIR / "opencode-go.json").read_text())
        self.assertIn("Tracked by Omarchy", data["usageStatusText"])

    # ------------------------------------------------------------------ #
    # Unwritable usage directory must never crash the collector
    # ------------------------------------------------------------------ #
    def test_unwritable_dir_contained(self):
        usage = self.m.USAGE_DIR
        usage.mkdir(parents=True, exist_ok=True)
        os.chmod(usage, stat.S_IRUSR | stat.S_IXUSR)  # read-only
        try:
            self.m.ensure_subscription_data()  # must not raise
        finally:
            os.chmod(usage, stat.S_IRWXU)
        self.assertTrue(True)

    # ------------------------------------------------------------------ #
    # Fetchers
    # ------------------------------------------------------------------ #
    def test_opencode_go_percent_clamped(self):
        with mock.patch.object(
            self.m,
            "_subscription_request_json",
            return_value={"usage": {"rolling": {"percent": 1e308, "resetsAt": "2026-01-01T00:00:00Z"}}},
        ):
            result = self.m._fetch_opencode_go("k")
        self.assertEqual(result["limits"][0]["percent"], 1.0)

    def test_opencode_go_negative_percent_clamped(self):
        with mock.patch.object(
            self.m, "_subscription_request_json", return_value={"usage": {"rolling": {"percent": -50}}}
        ):
            result = self.m._fetch_opencode_go("k")
        self.assertEqual(result["limits"][0]["percent"], 0.0)

    def test_commandcode_numeric_string_reset(self):
        with mock.patch.object(
            self.m,
            "_subscription_request_json",
            return_value={"windowLimits": {"fiveHour": {"cap": 100, "used": 25, "resetAt": "1790000000000"}}},
        ):
            result = self.m._fetch_command_code("k")
        self.assertEqual(result["limits"][0]["resetsAt"], "2026-09-21T14:13:20Z")

    def test_commandcode_balance_in_tier_label(self):
        with mock.patch.object(
            self.m,
            "_subscription_request_json",
            return_value={
                "credits": {"monthlyCredits": 69.0, "purchasedCredits": 0, "freeCredits": 0},
                "windowLimits": {"fiveHour": {"cap": 100, "used": 10}},
            },
        ):
            result = self.m._fetch_command_code("k")
        self.assertIn("$69.00", result["tierLabel"])

    def test_commandcode_balance_only_response_rejected(self):
        with mock.patch.object(
            self.m,
            "_subscription_request_json",
            return_value={"credits": {"monthlyCredits": 69.0}},
        ):
            with self.assertRaises(ValueError):
                self.m._fetch_command_code("k")

    def test_fetch_error_keeps_last_good_file(self):
        good = {"id": "commandcode", "ready": True, "limits": [{"title": "5h", "percent": 0.1}]}
        (self.m.USAGE_DIR / "commandcode.json").write_text(json.dumps(good))
        os.environ["COMMANDCODE_API_KEY"] = "test-key"
        with mock.patch.object(
            self.m, "_subscription_request_json", side_effect=TimeoutError("response deadline exceeded")
        ):
            self.m.ensure_subscription_data()
        self.assertEqual(json.loads((self.m.USAGE_DIR / "commandcode.json").read_text()), good)

    # ------------------------------------------------------------------ #
    # Transport
    # ------------------------------------------------------------------ #
    def test_oversized_response_rejected(self):
        response = mock.MagicMock()
        response.read.side_effect = lambda n: b"x" * n  # endless stream
        response.__enter__ = lambda s: response
        response.__exit__ = lambda s, *args: False
        with mock.patch.object(self.m, "_SUBSCRIPTION_OPENER") as opener:
            opener.open.return_value = response
            with self.assertRaises(ValueError):
                self.m._subscription_request_json("https://opencode.invalid/zen", "k")

    def test_slow_drip_response_hits_total_deadline(self):
        import time as time_mod

        response = mock.MagicMock()
        response.__enter__ = lambda s: response
        response.__exit__ = lambda s, *args: False

        def drip(n):
            time_mod.sleep(0.02)
            return b"x"

        response.read.side_effect = drip
        with mock.patch.object(self.m, "_SUBSCRIPTION_OPENER") as opener:
            opener.open.return_value = response
            with mock.patch.object(self.m, "SUBSCRIPTION_TOTAL_DEADLINE_S", 0.2):
                with self.assertRaises(TimeoutError):
                    self.m._subscription_request_json("https://opencode.invalid/zen", "k")

    # ------------------------------------------------------------------ #
    # Env file parser
    # ------------------------------------------------------------------ #
    def test_env_trailing_comment_and_quotes(self):
        self.envfile.write_text(
            "# comment\n"
            "OPENCODE_GO_API_KEY=abc123 # my note\n"
            'COMMANDCODE_API_KEY="quoted key" # trailing\n'
        )
        self.m._load_subscription_env_file()
        self.assertEqual(os.environ["OPENCODE_GO_API_KEY"], "abc123")
        self.assertEqual(os.environ["COMMANDCODE_API_KEY"], "quoted key")

    def test_env_hash_inside_quotes_preserved(self):
        self.envfile.write_text('OPENCODE_GO_API_KEY="val # with hash"\n')
        self.m._load_subscription_env_file()
        self.assertEqual(os.environ["OPENCODE_GO_API_KEY"], "val # with hash")

    def test_env_unquoted_hash_without_space_kept(self):
        self.envfile.write_text("OPENCODE_GO_API_KEY=abc#def\n")
        self.m._load_subscription_env_file()
        self.assertEqual(os.environ["OPENCODE_GO_API_KEY"], "abc#def")

    def test_env_first_occurrence_wins(self):
        self.envfile.write_text("OPENCODE_GO_API_KEY=first\nOPENCODE_GO_API_KEY=second\n")
        self.m._load_subscription_env_file()
        self.assertEqual(os.environ["OPENCODE_GO_API_KEY"], "first")

    def test_env_unknown_keys_ignored_and_real_env_has_precedence(self):
        self.envfile.write_text("OTHER_VAR=x\nOPENCODE_GO_API_KEY=from-file\n")
        os.environ["OPENCODE_GO_API_KEY"] = "from-env"
        self.m._load_subscription_env_file()
        self.assertEqual(os.environ["OPENCODE_GO_API_KEY"], "from-env")
        self.assertIsNone(os.environ.get("OTHER_VAR"))


if __name__ == "__main__":
    unittest.main()
