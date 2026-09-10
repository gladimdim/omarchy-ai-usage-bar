import QtQuick
import Quickshell
import Quickshell.Io

// Keep preferences outside both shell.json and the replaceable plugin checkout.
// The shell's inline entry remains a compatibility mirror, not the only copy.
QtObject {
  id: store

  property string path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
    + "/omarchy/ai-usage-bar.json"
  property var legacySettings: ({})
  property bool initialized: false
  property string error: ""
  readonly property var keys: ["tracked", "limitOrder", "barLength", "barStyle",
    "showPercent", "showReset", "showLabel", "coloredBars", "refreshIntervalSec"]
  readonly property var values: readValues()
  readonly property var effectiveSettings: {
    var result = ({})
    for (var key in legacySettings) result[key] = legacySettings[key]
    for (var saved in values) result[saved] = values[saved]
    return result
  }

  property FileView file: FileView {
    path: store.path
    blockLoading: true
    // Finish the small preferences write before a shell mirror can rebuild us.
    blockWrites: true
    atomicWrites: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onSaveFailed: function(code) {
      store.error = "Could not save AI Usage Bar preferences (" + code + ")."
      console.warn("gladimdim.ai-limits:", store.error)
    }
    onLoadFailed: function(code) {
      if (code !== FileViewError.FileNotFound)
        console.warn("gladimdim.ai-limits: could not read preferences:", code)
    }
  }

  function readValues() {
    var raw = file.text().trim()
    if (!raw) return ({})
    try {
      var parsed = JSON.parse(raw)
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed
    } catch (e) {
      console.warn("gladimdim.ai-limits: invalid preferences:", e)
    }
    return ({})
  }

  function writeValues(next) {
    error = ""
    file.setText(JSON.stringify(next, null, 2) + "\n")
    return error === ""
  }

  function importLegacy() {
    if (!initialized) return
    // A second monitor may already have saved while this instance was loading.
    file.reload()
    file.waitForJob()
    var next = readValues()
    var changed = false
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      if (next[key] === undefined && legacySettings[key] !== undefined) {
        next[key] = legacySettings[key]
        changed = true
      }
    }
    if (changed) writeValues(next)
  }

  function save(key, value) {
    // Merge against disk so another monitor's latest changes are preserved.
    file.reload()
    file.waitForJob()
    var next = readValues()
    for (var i = 0; i < keys.length; i++) {
      var name = keys[i]
      if (next[name] === undefined && legacySettings[name] !== undefined)
        next[name] = legacySettings[name]
    }
    next[key] = value
    return writeValues(next)
  }

  onLegacySettingsChanged: importLegacy()
  Component.onCompleted: {
    initialized = true
    importLegacy()
  }
}
