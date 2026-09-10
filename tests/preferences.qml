import QtQuick
import Quickshell
import Quickshell.Io
import "."

Scope {
  id: testCase
  property int serial: 0
  property var watchedStore: null

  Component { id: storeComponent; Preferences {} }
  Component { id: widgetComponent; SettingsWidget {} }

  function makeStore(path, legacy) {
    return storeComponent.createObject(testCase, {
      path: path,
      legacySettings: legacy || ({})
    })
  }

  function verify(value) {
    if (!value) throw new Error("Assertion failed")
  }

  function compare(actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected))
      throw new Error("Expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual))
  }

  function freshPath() {
    return Quickshell.env("AI_USAGE_TEST_DIR") + "/case-" + (++serial) + "/preferences.json"
  }

  function test_migrateAndRecreate() {
    var path = freshPath()
    var selection = ["claude:fable-weekly", "codex:weekly-7-day"]
    var first = makeStore(path, { tracked: selection, barStyle: "shaded" })
    compare(first.values.tracked, selection)
    verify(first.save("tracked", ["codex:weekly-7-day"]))
    first.destroy()

    // A rebuild injects old defaults: the durable choice must still win.
    var restarted = makeStore(path, {
      tracked: ["claude:session-5-hour", "grok:weekly"], barStyle: "blocks"
    })
    compare(restarted.effectiveSettings.tracked, ["codex:weekly-7-day"])
    compare(restarted.effectiveSettings.barStyle, "shaded")
    verify(restarted.save("tracked", []))
    restarted.destroy()
    compare(makeStore(path).effectiveSettings.tracked, [])
  }

  function test_lateHostInjection() {
    var store = makeStore(freshPath())
    compare(store.values, ({}))
    store.legacySettings = { tracked: ["codex:weekly-7-day"] }
    compare(store.values.tracked, ["codex:weekly-7-day"])
    store.legacySettings = { tracked: ["grok:weekly"] }
    compare(store.effectiveSettings.tracked, ["codex:weekly-7-day"])
  }

  function test_multipleInstancesMergeAndWatch() {
    var path = freshPath()
    var first = makeStore(path, { tracked: ["codex:weekly-7-day"] })
    var second = makeStore(path)
    verify(first.save("barStyle", "braille"))
    verify(second.save("tracked", ["claude:fable-weekly"]))
    compare(second.values.barStyle, "braille")
    watchedStore = first
  }

  function test_failedSaveReportsError() {
    // /proc never permits creation, including when tests run as root.
    var store = makeStore("/proc/ai-usage-bar-test/preferences.json")
    verify(!store.save("tracked", []))
    verify(store.error.length > 0)
  }

  function test_saveBeforeShellCallback() {
    var called = false
    var widget = widgetComponent.createObject(testCase, {
      settings: { tracked: ["grok:weekly"], barLength: 24 },
      bar: { shell: { updateEntryInline: function(id, entry) {
        called = true
        compare(id, "gladimdim.ai-limits")
        compare(entry.tracked, ["codex:weekly-7-day"])
        // The file must already be committed when this callback runs.
        var rebuilt = widgetComponent.createObject(testCase, {
          settings: { tracked: ["grok:weekly"] }
        })
        compare(rebuilt.effectiveSettings.tracked, ["codex:weekly-7-day"])
        compare(rebuilt.effectiveSettings.barLength, 24)
        rebuilt.destroy()
        return false
      } } }
    })
    widget.saveSetting("tracked", ["codex:weekly-7-day"])
    verify(called)
    // An unavailable shell API must not prevent subsequent durable saves.
    widget.bar = null
    widget.saveSetting("tracked", [])
    compare(widget.effectiveSettings.tracked, [])
    widget.destroy()
  }

  Timer {
    interval: 10
    running: true
    onTriggered: {
      try {
        if (Quickshell.env("AI_USAGE_TEST_RESTART") === "1") {
          var restored = makeStore(Quickshell.env("AI_USAGE_TEST_DIR") + "/restart.json", {
            tracked: ["claude:session-5-hour", "grok:weekly"]
          })
          compare(restored.effectiveSettings.tracked, ["codex:weekly-7-day"])
          console.log("PREFERENCES PASS")
          Qt.quit()
          return
        }
        test_migrateAndRecreate()
        test_lateHostInjection()
        test_multipleInstancesMergeAndWatch()
        test_failedSaveReportsError()
        test_saveBeforeShellCallback()
        var persisted = makeStore(Quickshell.env("AI_USAGE_TEST_DIR") + "/restart.json")
        verify(persisted.save("tracked", ["codex:weekly-7-day"]))
        watcherCheck.start()
      } catch (e) {
        console.error("PREFERENCES FAIL:", e.stack)
        Qt.quit()
      }
    }
  }

  Timer {
    id: watcherCheck
    interval: 300
    onTriggered: {
      try {
        compare(testCase.watchedStore.values.tracked, ["claude:fable-weekly"])
        compare(testCase.watchedStore.values.barStyle, "braille")
        console.log("PREFERENCES PASS")
      } catch (e) {
        console.error("PREFERENCES FAIL:", e.stack)
      }
      Qt.quit()
    }
  }
}
