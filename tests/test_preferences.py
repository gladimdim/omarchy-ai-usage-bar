"""Run real Quickshell persistence checks without touching desktop settings.

Run with: python3 -m unittest discover -s tests
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class PreferencesTest(unittest.TestCase):
    def test_persistence_and_process_restart(self):
        with tempfile.TemporaryDirectory(prefix="ai-usage-tests-") as directory:
            tests = Path(__file__).parent
            shutil.copy(tests / "preferences.qml", Path(directory) / "shell.qml")
            shutil.copy(tests.parent / "Preferences.qml", directory)
            # Test the real widget save function with a shell callback that
            # immediately recreates the preferences consumer.
            qml = (tests.parent / "Widget.qml").read_text()
            start = qml.index("  function saveSetting(")
            end = qml.index("\n  }", start) + 4
            (Path(directory) / "SettingsWidget.qml").write_text(
                'import QtQuick\nItem {\n id: root\n'
                ' property var settings: ({})\n property var bar: null\n'
                ' property string moduleName: "gladimdim.ai-limits"\n'
                ' property string selectionWarning: ""\n'
                ' readonly property var effectiveSettings: preferences.effectiveSettings\n'
                ' Preferences { id: preferences; legacySettings: root.settings }\n'
                + qml[start:end] + '\n}\n')
            env = dict(os.environ, AI_USAGE_TEST_DIR=directory,
                       XDG_RUNTIME_DIR=directory, XDG_CONFIG_HOME=directory,
                       QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="basic",
                       QT_QUICK_CONTROLS_STYLE="Basic")
            env.pop("WAYLAND_DISPLAY", None)
            for restart in ("0", "1"):
                env["AI_USAGE_TEST_RESTART"] = restart
                result = subprocess.run(
                    ["quickshell", "-p", directory,
                     "--no-color"], env=env, capture_output=True, text=True, timeout=15)
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0, output)
                self.assertIn("PREFERENCES PASS", output)
                self.assertNotIn("PREFERENCES FAIL", output)
                self.assertNotIn("Binding loop", output)
                saved = json.loads((Path(directory) / "restart.json").read_text())
                self.assertEqual(saved["tracked"], ["codex:weekly-7-day"])
