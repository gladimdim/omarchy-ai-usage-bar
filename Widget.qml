import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "gladimdim.ai-limits"

  property bool pressable: true
  property bool interactive: true
  property bool popupOpen: false
  property int activeTab: 0 // 0: Dock Tracker, 1: All Providers, 2: Style & Options
  property bool refreshing: false
  property bool currentRefreshIsForce: false
  property bool pendingRefreshForce: false
  property string statusMessage: ""
  property double nowMs: Date.now()

  onPopupOpenChanged: {
    if (popupOpen) {
      root.triggerRefresh(true)
    }
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color background: Color.popups.background
  readonly property color border: Color.popups.border
  readonly property color urgent: Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.45)
  readonly property color cardBg: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.05)
  readonly property color cardHover: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.09)
  readonly property color cardBorder: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property string fontFamily: bar ? bar.fontFamily : "JetBrainsMono Nerd Font"
  readonly property int radiusVal: Style.cornerRadius > 0 ? Math.min(6, Style.cornerRadius) : 6

  function toList(val, fallback) {
    if (!val) return fallback ? fallback.slice() : []
    var res = []
    if (typeof val.length === "number") {
      for (var i = 0; i < val.length; i++) res.push(val[i])
      return res
    }
    return fallback ? fallback.slice() : []
  }

  // Settings from shell.json (Strictly capped at max 2, directly reactive to root.settings)
  readonly property var trackedSettings: {
    var raw = root.settings && root.settings.tracked !== undefined
      ? root.settings.tracked
      : ["claude:session-5-hour", "grok:weekly"]
    return root.toList(raw, ["claude:session-5-hour", "grok:weekly"]).slice(0, 2)
  }
  readonly property int trackedCount: root.toList(trackedSettings, []).length
  property string selectionWarning: ""
  readonly property int barLength: Math.max(8, Math.min(32, Number(root.settings && root.settings.barLength !== undefined ? root.settings.barLength : 16)))
  readonly property string barStyle: String(root.settings && root.settings.barStyle !== undefined ? root.settings.barStyle : "blocks")
  readonly property bool showPercent: Boolean(root.settings && root.settings.showPercent !== undefined ? root.settings.showPercent : true)
  readonly property bool showReset: Boolean(root.settings && root.settings.showReset !== undefined ? root.settings.showReset : true)
  readonly property bool showLabel: Boolean(root.settings && root.settings.showLabel !== undefined ? root.settings.showLabel : true)
  readonly property bool coloredBars: Boolean(root.settings && root.settings.coloredBars !== undefined ? root.settings.coloredBars : true)
  readonly property int refreshIntervalSec: Math.max(10, Number(root.settings && root.settings.refreshIntervalSec !== undefined ? root.settings.refreshIntervalSec : 60))

  // The order the user arranged the limits into, as limit ids. Only a provider
  // whose rows have been nudged appears here; everything unlisted keeps the
  // collector's order (percent, descending) behind whatever was arranged.
  // Position within a provider is what matters — the first of its ids is that
  // provider's headline limit, the one the folded panel header reports.
  readonly property var limitOrderSettings: root.toList(
    root.settings && root.settings.limitOrder !== undefined ? root.settings.limitOrder : [],
    [])

  // Data state
  property var limitsData: ({ "providers": [], "allLimits": [] })
  property var providers: limitsData && limitsData.providers ? limitsData.providers : []
  property var allLimits: limitsData && limitsData.allLimits ? limitsData.allLimits : []
  property var trackedItems: []

  readonly property string scriptPath: pathFromUrl(Qt.resolvedUrl("collect.py"))

  function pathFromUrl(url) {
    var val = String(url || "")
    if (val.indexOf("file://") === 0) return decodeURIComponent(val.substring(7))
    return val
  }

  function clamp(v, min, max) {
    return Math.max(min, Math.min(max, v))
  }

  function updateTrackedItems() {
    var result = []
    var trackedList = root.toList(trackedSettings, []).slice(0, 2)
    var limits = limitsData && limitsData.allLimits ? limitsData.allLimits : []
    var byId = {}

    for (var i = 0; i < limits.length; i++) {
      var item = limits[i]
      if (item && item.id) byId[item.id] = item
    }

    // Match configured tracked IDs
    for (var j = 0; j < trackedList.length; j++) {
      var tid = trackedList[j]
      if (byId[tid]) {
        result.push(byId[tid])
        if (result.length >= 2) break
      }
    }

    // Fallback: pick top 2 if none matched or empty
    if (result.length === 0 && limits.length > 0) {
      for (var k = 0; k < limits.length; k++) {
        result.push(limits[k])
        if (result.length >= 2) break
      }
    }

    trackedItems = result.slice(0, 2)
  }

  onLimitsDataChanged: updateTrackedItems()
  onAllLimitsChanged: updateTrackedItems()
  onTrackedSettingsChanged: updateTrackedItems()

  // ---------------------------------------------- Provider grouping / collapse
  // Limits grouped by their provider, in the order the user arranged them —
  // `limitOrder` first, then everything it does not mention in the collector's
  // own order. Each group also names its `topLimit`: the row sitting first, which
  // is what the header shows for the whole provider.
  readonly property var groupedLimits: {
    var groups = []
    var byId = ({})
    var limits = root.allLimits

    // id -> arranged position. Compared only within one provider, so the
    // absolute numbers never matter, just their relative order.
    var rank = ({})
    var order = root.limitOrderSettings
    for (var o = 0; o < order.length; o++) rank[String(order[o])] = o

    for (var i = 0; i < limits.length; i++) {
      var lim = limits[i]
      if (!lim) continue
      var pid = lim.providerId || "unknown"
      var group = byId[pid]
      if (!group) {
        group = {
          "providerId": pid,
          "providerName": lim.providerName || pid,
          "color": lim.color || root.accent,
          "peakPercent": 0.0,
          "topLimit": null,
          "rows": [],
          "limits": []
        }
        byId[pid] = group
        groups.push(group)
      }
      // `seq` keeps the collector's order as the tie-break, so unarranged rows
      // do not shuffle on a sort that makes no promise about equal elements.
      group.rows.push({ "lim": lim, "seq": group.rows.length })
      if (Number(lim.percent || 0) > group.peakPercent) group.peakPercent = Number(lim.percent || 0)
    }

    for (var g = 0; g < groups.length; g++) {
      var rows = groups[g].rows
      rows.sort(function (a, b) {
        var ra = rank[a.lim.id]
        var rb = rank[b.lim.id]
        var hasA = ra !== undefined
        var hasB = rb !== undefined
        if (hasA && hasB) return ra - rb
        if (hasA) return -1   // arranged rows sit above unarranged ones
        if (hasB) return 1
        return a.seq - b.seq
      })
      var ordered = []
      for (var r = 0; r < rows.length; r++) ordered.push(rows[r].lim)
      groups[g].limits = ordered
      groups[g].topLimit = ordered.length > 0 ? ordered[0] : null
      groups[g].rows = []
    }

    return groups
  }

  // providerId -> true when the panel is folded shut. Replaced wholesale on each
  // change so bindings that read it re-evaluate.
  property var collapsedProviders: ({})

  function isProviderCollapsed(providerId) {
    return root.collapsedProviders[providerId] === true
  }

  function toggleProviderCollapsed(providerId) {
    var next = ({})
    for (var k in root.collapsedProviders) next[k] = root.collapsedProviders[k]
    next[providerId] = !(next[providerId] === true)
    root.collapsedProviders = next
  }

  function allProviderIds() {
    var ids = []
    var seen = ({})
    var groups = root.groupedLimits
    for (var i = 0; i < groups.length; i++) {
      seen[groups[i].providerId] = true
      ids.push(groups[i].providerId)
    }
    var provs = root.providers
    for (var j = 0; j < provs.length; j++) {
      if (provs[j] && !seen[provs[j].id]) {
        seen[provs[j].id] = true
        ids.push(provs[j].id)
      }
    }
    return ids
  }

  function anyProviderCollapsed() {
    var ids = root.allProviderIds()
    for (var i = 0; i < ids.length; i++) if (root.collapsedProviders[ids[i]] === true) return true
    return false
  }

  function setAllProvidersCollapsed(collapsed) {
    var next = ({})
    if (collapsed) {
      var ids = root.allProviderIds()
      for (var i = 0; i < ids.length; i++) next[ids[i]] = true
    }
    root.collapsedProviders = next
  }

  function toggleAllProviders() {
    root.setAllProvidersCollapsed(!root.anyProviderCollapsed())
  }

  // The limit standing first in a provider's panel — the one that speaks for the
  // provider in its header. Null for a provider with nothing to report.
  function headLimitOf(providerId) {
    var groups = root.groupedLimits
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].providerId === providerId) return groups[i].topLimit
    }
    return null
  }

  // Nudge a limit one row up (delta -1) or down (+1) inside its own provider.
  // Rows never cross providers: the panels are the grouping, and moving between
  // them would mean re-labelling the limit, not re-ordering it.
  function moveLimit(providerId, limitId, delta) {
    var groups = root.groupedLimits
    var lims = null
    for (var g = 0; g < groups.length; g++) {
      if (groups[g].providerId === providerId) { lims = groups[g].limits; break }
    }
    if (!lims) return

    var ids = []
    for (var i = 0; i < lims.length; i++) ids.push(String(lims[i].id))
    var from = ids.indexOf(String(limitId))
    var to = from + delta
    if (from === -1 || to < 0 || to >= ids.length) return
    ids.splice(to, 0, ids.splice(from, 1)[0])

    // Persist this provider's whole order and leave every other provider's
    // saved ids alone — one nudge must not re-arrange a panel nobody touched.
    var next = []
    var saved = root.toList(root.limitOrderSettings, [])
    for (var s = 0; s < saved.length; s++) {
      var sid = String(saved[s])
      if (sid.indexOf(providerId + ":") !== 0) next.push(sid)
    }
    for (var k = 0; k < ids.length; k++) next.push(ids[k])

    root.saveSetting("limitOrder", next)
  }

  // Highest usage among a provider's limits, for the collapsed summary.
  function peakPercentOf(limits) {
    var list = root.toList(limits, [])
    var peak = 0.0
    for (var i = 0; i < list.length; i++) {
      var v = Number(list[i] && list[i].percent || 0)
      if (v > peak) peak = v
    }
    return peak
  }

  // How many of a provider's limits are currently pinned to the dock.
  function trackedCountForProvider(providerId) {
    var tracked = root.toList(root.trackedSettings, [])
    var count = 0
    for (var i = 0; i < tracked.length; i++) {
      var tid = String(tracked[i] || "")
      if (tid.indexOf(providerId + ":") === 0) count++
    }
    return count
  }

  function makeAsciiBar(percent, length, style) {
    var clamped = Math.max(0.0, Math.min(1.0, Number(percent || 0.0)))
    var len = Math.max(6, Math.min(40, length || 16))
    var fillCount = Math.round(clamped * len)
    var emptyCount = len - fillCount

    if (style === "ascii") {
      if (fillCount === 0) return "[" + " ".repeat(len) + "]"
      if (fillCount === len) return "[" + "=".repeat(len) + "]"
      return "[" + "=".repeat(Math.max(0, fillCount - 1)) + ">" + " ".repeat(emptyCount) + "]"
    } else if (style === "retro") {
      return "[" + "#".repeat(fillCount) + "-".repeat(emptyCount) + "]"
    } else if (style === "squares") {
      return "[" + "■".repeat(fillCount) + "□".repeat(emptyCount) + "]"
    } else if (style === "shaded") {
      return "[" + "▓".repeat(fillCount) + "░".repeat(emptyCount) + "]"
    } else if (style === "braille") {
      return "[" + "⣿".repeat(fillCount) + "⣀".repeat(emptyCount) + "]"
    } else { // blocks (default)
      return "[" + "█".repeat(fillCount) + "░".repeat(emptyCount) + "]"
    }
  }

  function cycleStyle() {
    var styles = ["blocks", "shaded", "ascii", "retro", "squares", "braille"]
    var idx = styles.indexOf(barStyle)
    var next = styles[(idx + 1) % styles.length]
    saveSetting("barStyle", next)
  }

  function isLimitTracked(limitId) {
    var trackedList = root.toList(root.trackedSettings, [])
    return trackedList.indexOf(limitId) !== -1
  }

  function toggleTrackLimit(limitId) {
    var trackedList = root.toList(root.trackedSettings, []).slice(0, 2)
    var idx = trackedList.indexOf(limitId)

    if (idx !== -1) {
      trackedList.splice(idx, 1)
      root.selectionWarning = ""
    } else {
      if (trackedList.length >= 2) {
        trackedList.shift()
        trackedList.push(limitId)
        root.selectionWarning = "Max 2 tracked: replaced oldest selection."
        warningTimer.restart()
      } else {
        trackedList.push(limitId)
        root.selectionWarning = ""
      }
    }

    saveSetting("tracked", trackedList.slice(0, 2))
  }

  function saveSetting(key, value) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    entry[key] = value
    root.settings = entry

    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    }
  }

  function triggerRefresh(force) {
    if (collectorProc.running) {
      if (force === true && !root.currentRefreshIsForce) {
        root.pendingRefreshForce = true
      }
      return
    }
    root.currentRefreshIsForce = (force === true)
    root.refreshing = true
    if (force === true) {
      autoRefreshTimer.restart()
    }
    collectorProc.command = force === true
      ? ["python3", root.scriptPath, "--refresh"]
      : ["python3", root.scriptPath]
    collectorProc.running = true
  }

  function applyData(rawText) {
    if (!root.pendingRefreshForce) {
      root.refreshing = false
    }
    var raw = String(rawText || "").trim()
    if (raw === "") return
    try {
      var parsed = JSON.parse(raw)
      if (parsed && (parsed.providers || parsed.allLimits)) {
        root.limitsData = parsed
        root.nowMs = Date.now()
        root.updateTrackedItems()
        root.detectLimitEvents(parsed.allLimits)
      }
    } catch (e) {
      console.warn("gladimdim.ai-limits: parse error", e)
    }
  }

  Process {
    id: collectorProc
    running: false
    command: ["python3", root.scriptPath]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyData(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: function(text) {
        if (text && text.trim() !== "") console.warn("gladimdim.ai-limits:", text.trim())
      }
    }

    onExited: {
      root.currentRefreshIsForce = false
      if (root.pendingRefreshForce) {
        root.pendingRefreshForce = false
        Qt.callLater(function() {
          root.triggerRefresh(true)
        })
      } else {
        root.refreshing = false
      }
    }
  }

  Timer {
    id: autoRefreshTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.triggerRefresh(true)
  }

  Timer {
    interval: 5000
    running: root.popupOpen
    repeat: true
    onTriggered: root.triggerRefresh(false)
  }

  Timer {
    id: warningTimer
    interval: 3500
    repeat: false
    running: false
    onTriggered: root.selectionWarning = ""
  }

  Component.onCompleted: {
    root.triggerRefresh(true)
  }

  function tooltipContent() {
    var items = trackedItems
    if (!items || items.length === 0) return "AI Usage Bar\n(Click to configure)"
    var lines = root.activeEvent !== null
      ? [root.activeEvent.text, ""]
      : ["AI Usage Bar (Click for details)"]
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      var rText = item.resetsFormatted ? " (" + item.resetsFormatted + ")" : ""
      lines.push("• " + item.providerName + " " + item.title + ": " + item.percentInt + "%" + rText)
    }
    return lines.join("\n")
  }

  function open() {
    if (!popupOpen) {
      popupOpen = true
    } else {
      triggerRefresh(true)
    }
  }

  function close() {
    popupOpen = false
  }

  function toggle() {
    if (popupOpen) close()
    else open()
  }

  function closeForPopoutSwitch() {
    close()
  }

  function triggerPress(btn) {
    if (btn === Qt.RightButton) {
      cycleStyle()
      return
    }
    if (btn === Qt.MiddleButton) {
      triggerRefresh(true)
      return
    }
    toggle()
  }

  // ------------------------------------------------------------- Dock Bar UI
  implicitWidth: dockItem.implicitWidth
  implicitHeight: root.barSize

  Item {
    id: dockItem
    anchors.fill: parent
    implicitWidth: Math.max(36, dockContent.implicitWidth + Style.space(16))
    implicitHeight: root.barSize

    property bool pressable: true
    property bool interactive: true
    property var registeredBar: null

    function triggerPress(button) {
      root.triggerPress(button)
    }

    function syncClickRegistration() {
      if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(dockItem)
      registeredBar = root.bar
      if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(dockItem)
    }
    Component.onCompleted: syncClickRegistration()
    Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(dockItem)
    Connections {
      target: root
      function onBarChanged() { dockItem.syncClickRegistration() }
    }

    MouseArea {
      id: mouseArea
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (root.bar) root.bar.showTooltip(dockItem, root.tooltipContent())
      onExited: if (root.bar) root.bar.hideTooltip(dockItem)
      onClicked: function(mouse) { root.triggerPress(mouse.button) }
    }

    // Pulsing halo while an announcement is waiting to be read in the popup.
    Rectangle {
      id: eventGlow
      anchors.centerIn: dockContent
      width: dockContent.width + Style.space(12)
      height: Math.min(dockItem.height - 2, dockContent.height + Style.space(6))
      radius: root.radiusVal
      visible: root.activeEvent !== null && !root.popupOpen

      property real rainbow: 0
      NumberAnimation on rainbow {
        running: eventGlow.visible && root.activeEvent !== null && root.activeEvent.kind === "reset"
        loops: Animation.Infinite
        from: 0
        to: 1
        duration: 2400
      }

      color: root.activeEvent && root.activeEvent.kind === "reset"
        ? Qt.hsla(eventGlow.rainbow, 0.8, 0.55, 0.35)
        : Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35)

      SequentialAnimation on opacity {
        running: eventGlow.visible
        loops: Animation.Infinite
        NumberAnimation { from: 0.1; to: 0.55; duration: 750; easing.type: Easing.InOutQuad }
        NumberAnimation { from: 0.55; to: 0.1; duration: 750; easing.type: Easing.InOutQuad }
      }
    }

    // Centered Dock Content
    Item {
      id: dockContent
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: root.dockShake
      implicitWidth: root.trackedItems.length === 1 ? singleRow.implicitWidth : multiColumn.implicitWidth
      implicitHeight: root.trackedItems.length === 1 ? singleRow.implicitHeight : multiColumn.implicitHeight

      // Fallback if no limits found
      Text {
        visible: root.trackedItems.length === 0
        anchors.centerIn: parent
        text: "[ AI Usage ]"
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: 10
        renderType: Text.NativeRendering
      }

      // 1 Line Mode (When exactly 1 provider is tracked)
      Row {
        id: singleRow
        visible: root.trackedItems.length === 1
        anchors.centerIn: parent
        spacing: 6

        readonly property var item: root.trackedItems.length > 0 ? root.trackedItems[0] : null

        Text {
          visible: root.showLabel && singleRow.item !== null
          text: singleRow.item ? singleRow.item.shortLabel : ""
          color: root.dockLabelColor(singleRow.item)
          font.family: root.fontFamily
          font.pixelSize: 10
          font.bold: true
          renderType: Text.NativeRendering
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          visible: singleRow.item !== null
          text: root.dockBarText(singleRow.item)
          color: root.dockBarColor(singleRow.item)
          font.family: root.fontFamily
          font.pixelSize: 10
          renderType: Text.NativeRendering
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          visible: root.showPercent && singleRow.item !== null
          text: singleRow.item ? singleRow.item.percentInt + "%" : ""
          color: root.dockPercentColor(singleRow.item)
          font.family: root.fontFamily
          font.pixelSize: 10
          font.bold: (singleRow.item && singleRow.item.percent >= 0.95) || root.isEventRow(singleRow.item)
          renderType: Text.NativeRendering
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          visible: root.showReset && singleRow.item !== null && singleRow.item.resetsShort !== ""
          text: singleRow.item ? singleRow.item.resetsShort : ""
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: 9
          renderType: Text.NativeRendering
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      // 2 Lines Stacked Mode (When 2 providers are tracked)
      Column {
        id: multiColumn
        visible: root.trackedItems.length >= 2
        anchors.centerIn: parent
        spacing: 0

        Repeater {
          model: root.trackedItems.slice(0, 2)

          Item {
            id: lineItem
            required property var modelData
            implicitWidth: lineRow.implicitWidth
            implicitHeight: 11

            Row {
              id: lineRow
              spacing: 4
              anchors.verticalCenter: parent.verticalCenter

              // Provider short label with fixed alignment
              Item {
                visible: root.showLabel
                width: 68
                height: 11
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.shortLabel
                  color: root.dockLabelColor(modelData)
                  font.family: root.fontFamily
                  font.pixelSize: 9
                  font.bold: true
                  renderType: Text.NativeRendering
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              // ASCII progress bar
              Text {
                text: root.dockBarText(modelData)
                color: root.dockBarColor(modelData)
                font.family: root.fontFamily
                font.pixelSize: 9
                renderType: Text.NativeRendering
                anchors.verticalCenter: parent.verticalCenter
              }

              // Percentage with right alignment
              Item {
                visible: root.showPercent
                width: 28
                height: 11
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.percentInt + "%"
                  color: root.dockPercentColor(modelData)
                  font.family: root.fontFamily
                  font.pixelSize: 9
                  font.bold: modelData.percent >= 0.95 || root.isEventRow(modelData)
                  renderType: Text.NativeRendering
                }
              }

              // Reset countdown
              Item {
                visible: root.showReset && modelData.resetsShort !== ""
                width: 34
                height: 11
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.resetsShort
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: 8
                  renderType: Text.NativeRendering
                }
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------- Limit lifecycle events
  // A limit hitting 100% or rolling over into a fresh window raises an event
  // that the popup announces with a scrolling marquee.
  property var lastPercents: ({})
  property bool percentsSeeded: false
  property var eventQueue: []
  property var activeEvent: null

  readonly property int eventStaleMs: 30 * 60 * 1000
  // How long one announcement plays before it auto-dismisses, both in the
  // popup banner and as the dock bar animation.
  readonly property int eventDurationMs: 30000

  readonly property var depletedQuips: [
    "Ooops, tokens for %1 depleted!",
    "%1 just ran dry — time to go touch some grass 🌱",
    "That's all folks: %1 is fresh out of tokens 🍿",
    "RIP %1 tokens. Gone, but not forgotten 🪦",
    "%1 hit 100%. Even robots need a nap 😴",
    "Congrats, you maxed out %1. Impressive. Concerning. 🏆"
  ]

  readonly property var resetQuips: [
    "%1 refilled — go wild! 🌈",
    "Fresh tokens for %1, the quota gods have smiled ✨",
    "%1 is back from the dead! 🧟",
    "Ka-ching! %1 just reset 🎰",
    "New window, new you: %1 is topped up 🚀"
  ]

  function limitLabel(lim) {
    if (!lim) return "that limit"
    var name = lim.providerName ? String(lim.providerName) : ""
    var title = lim.title ? String(lim.title) : ""
    if (name !== "" && title !== "") return name + " " + title
    return name !== "" ? name : (title !== "" ? title : "that limit")
  }

  function pushLimitEvent(kind, lim) {
    var quips = kind === "depleted" ? root.depletedQuips : root.resetQuips
    var quip = quips[Math.floor(Math.random() * quips.length)]

    var queued = root.eventQueue.slice()
    queued.push({
      "kind": kind,
      "id": lim && lim.id ? lim.id : "",
      "text": String(quip).arg(root.limitLabel(lim)),
      "at": Date.now()
    })
    // Never let a long unattended session pile up a backlog.
    if (queued.length > 6) queued = queued.slice(queued.length - 6)
    root.eventQueue = queued

    if (root.activeEvent === null) root.advanceEvent()
  }

  function advanceEvent() {
    var queued = root.eventQueue.slice()
    var now = Date.now()

    while (queued.length > 0) {
      var ev = queued.shift()
      if (now - ev.at <= root.eventStaleMs) {
        root.eventQueue = queued
        root.activeEvent = ev
        return
      }
    }

    root.eventQueue = queued
    root.activeEvent = null
  }

  function dismissEvent() {
    root.advanceEvent()
  }

  // Compares each refresh against the previous one to spot depletions/resets.
  function detectLimitEvents(limits) {
    var list = root.toList(limits, [])
    var next = ({})
    var seeded = root.percentsSeeded

    for (var i = 0; i < list.length; i++) {
      var lim = list[i]
      if (!lim || !lim.id) continue

      var current = Number(lim.percent || 0)
      next[lim.id] = current
      if (!seeded) continue

      var before = root.lastPercents[lim.id]
      if (before === undefined) continue

      if (current >= 0.999 && before < 0.999) root.pushLimitEvent("depleted", lim)
      else if (before - current >= 0.2) root.pushLimitEvent("reset", lim)
    }

    root.lastPercents = next
    root.percentsSeeded = true
  }

  // Announcement lives for eventDurationMs (30s) whether the popup is open
  // or not, then auto-dismisses from both the popup banner and the dock bar
  // animation. Clicking the banner still dismisses it early.
  Timer {
    id: eventTimer
    interval: root.eventDurationMs
    repeat: false
    running: root.activeEvent !== null
    onTriggered: root.advanceEvent()
  }

  // Each queued announcement gets its own full 30s once it becomes active:
  // without this, promoting event B while the timer is already running for
  // event A would cut B's lifetime short.
  onActiveEventChanged: if (root.activeEvent !== null) eventTimer.restart()

  // ------------------------------------------- Dock animation during an event
  // While an announcement is active and the popup is closed, the tracked rows
  // in the bar animate: a scanner sweeps the bar of a depleted limit, a refill
  // wave runs across a limit that just reset. The eventTimer above clears the
  // active event after eventDurationMs (30s), which stops this animation too.
  readonly property bool dockEventActive: root.activeEvent !== null && !root.popupOpen
  readonly property bool dockEventReset: root.dockEventActive && root.activeEvent.kind === "reset"

  // True when the limit the event is about is actually pinned to the dock.
  readonly property bool dockEventTargeted: {
    if (root.activeEvent === null) return false
    var items = root.trackedItems
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i].id === root.activeEvent.id) return true
    }
    return false
  }

  property int dockTick: 0
  property real dockPulse: 0
  property real dockRainbow: 0
  property real dockShake: 0

  Timer {
    interval: 90
    repeat: true
    running: root.dockEventActive
    onTriggered: root.dockTick++
    onRunningChanged: if (!running) root.dockTick = 0
  }

  SequentialAnimation on dockPulse {
    running: root.dockEventActive && !root.dockEventReset
    loops: Animation.Infinite
    NumberAnimation { from: 0.0; to: 1.0; duration: 520; easing.type: Easing.InOutQuad }
    NumberAnimation { from: 1.0; to: 0.0; duration: 520; easing.type: Easing.InOutQuad }
  }

  NumberAnimation on dockRainbow {
    running: root.dockEventReset
    loops: Animation.Infinite
    from: 0.0
    to: 1.0
    duration: 1800
  }

  // An occasional nudge, not a permanent jitter.
  SequentialAnimation on dockShake {
    running: root.dockEventActive && !root.dockEventReset
    loops: Animation.Infinite
    NumberAnimation { from: 0; to: 2; duration: 70 }
    NumberAnimation { from: 2; to: -2; duration: 130 }
    NumberAnimation { from: -2; to: 0; duration: 70 }
    PauseAnimation { duration: 1100 }
  }

  // Does this dock row take part in the current announcement? If the limit in
  // question is not pinned to the dock at all, every row joins in instead.
  function isEventRow(item) {
    if (!root.dockEventActive || !item) return false
    return root.dockEventTargeted ? item.id === root.activeEvent.id : true
  }

  function barGlyphs(style) {
    if (style === "ascii") return ["=", " "]
    if (style === "retro") return ["#", "-"]
    if (style === "squares") return ["■", "□"]
    if (style === "shaded") return ["▓", "░"]
    if (style === "braille") return ["⣿", "⣀"]
    return ["█", "░"]
  }

  function makeEventBar(length, style) {
    var len = Math.max(6, Math.min(40, length || 16))
    var glyphs = root.barGlyphs(style)
    var out = ""
    var i

    if (root.dockEventReset) {
      // Refill wave running left to right, with a short beat before it repeats.
      var head = root.dockTick % (len + 5)
      for (i = 0; i < len; i++) out += (i < head ? glyphs[0] : glyphs[1])
    } else {
      // Larson scanner: a gap sweeping back and forth across a full bar.
      var span = Math.max(1, (len - 1) * 2)
      var pos = root.dockTick % span
      if (pos >= len) pos = span - pos
      for (i = 0; i < len; i++) out += (Math.abs(i - pos) <= 1 ? glyphs[1] : glyphs[0])
    }

    return "[" + out + "]"
  }

  function dockBarText(item) {
    if (!item) return ""
    if (root.isEventRow(item)) return root.makeEventBar(root.barLength, root.barStyle)
    return root.makeAsciiBar(item.percent, root.barLength, root.barStyle)
  }

  function dockEventColor() {
    if (root.dockEventReset) return Qt.hsla(root.dockRainbow, 0.85, 0.62, 1.0)
    return Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.45 + 0.55 * root.dockPulse)
  }

  function dockBarColor(item) {
    if (!item) return root.foreground
    if (root.isEventRow(item)) return root.dockEventColor()
    return item.percent >= 0.95
      ? root.urgent
      : (root.coloredBars ? item.color : root.foreground)
  }

  function dockLabelColor(item) {
    if (!item) return root.foreground
    if (root.isEventRow(item)) return root.dockEventColor()
    return root.coloredBars ? item.color : root.foreground
  }

  function dockPercentColor(item) {
    if (!item) return root.foreground
    if (root.isEventRow(item)) return root.dockEventColor()
    return item.percent >= 0.95 ? root.urgent : root.foreground
  }

  // Expand / collapse every provider panel at once.
  component FoldAllButton: Rectangle {
    implicitWidth: foldAllLabel.implicitWidth + Style.space(16)
    implicitHeight: Style.space(22)
    radius: root.radiusVal
    color: foldAllArea.containsMouse ? root.cardHover : root.cardBg
    border.color: root.cardBorder

    Text {
      id: foldAllLabel
      anchors.centerIn: parent
      text: root.anyProviderCollapsed() ? "⊞ Expand all" : "⊟ Collapse all"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: foldAllArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleAllProviders()
    }
  }

  // ------------------------------------------------------------- Popup Dialog
  KeyboardPanel {
    id: panel
    anchorItem: dockItem
    owner: root
    bar: root.bar
    open: root.popupOpen
    onOpenChanged: {
      if (root.popupOpen !== open) {
        root.popupOpen = open
      }
    }
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(Style.space(540), Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.triggerRefresh(true)
        if (t === "1") root.activeTab = 0
        if (t === "2") root.activeTab = 1
        if (t === "3") root.activeTab = 2
        if (t === "c" || t === "C") root.cycleStyle()
        if (t === "e" || t === "E") root.toggleAllProviders()
      }

      ColumnLayout {
        id: popupContent
        anchors.fill: parent
        spacing: Style.space(10)

        // Header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            text: "󰚩"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }

          ColumnLayout {
            spacing: 1
            Layout.fillWidth: true

            Text {
              text: "AI Usage & Limits"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              text: "Old School ASCII Dock Tracker"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // Refresh Button
          Rectangle {
            width: Style.space(28)
            height: Style.space(28)
            radius: root.radiusVal
            color: refArea.containsMouse ? root.cardHover : root.cardBg
            border.color: root.cardBorder

            Text {
              anchors.centerIn: parent
              text: "󰑐"
              color: root.refreshing ? root.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body

              RotationAnimation on rotation {
                running: root.refreshing
                from: 0
                to: 360
                loops: Animation.Infinite
                duration: 900
              }
            }

            MouseArea {
              id: refArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.triggerRefresh(true)
            }
          }

          // Close Button
          Rectangle {
            width: Style.space(28)
            height: Style.space(28)
            radius: root.radiusVal
            color: closeArea.containsMouse ? root.cardHover : root.cardBg
            border.color: root.cardBorder

            Text {
              anchors.centerIn: parent
              text: "✕"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: closeArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.close()
            }
          }
        }

        // Navigation Tab Bar
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Rectangle {
            Layout.fillWidth: true
            height: Style.space(30)
            radius: root.radiusVal
            color: root.activeTab === 0 ? root.accent : root.cardBg
            border.color: root.cardBorder

            Text {
              anchors.centerIn: parent
              text: "Tracked in Dock (" + root.trackedItems.length + "/2)"
              color: root.activeTab === 0 ? "#000000" : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activeTab = 0
            }
          }

          Rectangle {
            Layout.fillWidth: true
            height: Style.space(30)
            radius: root.radiusVal
            color: root.activeTab === 1 ? root.accent : root.cardBg
            border.color: root.cardBorder

            Text {
              anchors.centerIn: parent
              text: "All Providers (" + root.providers.length + ")"
              color: root.activeTab === 1 ? "#000000" : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activeTab = 1
            }
          }

          Rectangle {
            Layout.fillWidth: true
            height: Style.space(30)
            radius: root.radiusVal
            color: root.activeTab === 2 ? root.accent : root.cardBg
            border.color: root.cardBorder

            Text {
              anchors.centerIn: parent
              text: "Style & Options"
              color: root.activeTab === 2 ? "#000000" : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activeTab = 2
            }
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.foreground
        }

        // Warning banner when user attempts to select more than 2
        Rectangle {
          id: warningBanner
          visible: root.selectionWarning !== ""
          Layout.fillWidth: true
          implicitHeight: warningRow.implicitHeight + Style.space(12)
          radius: root.radiusVal
          color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.18)
          border.color: root.urgent
          border.width: 1

          RowLayout {
            id: warningRow
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(8)

            Text {
              text: "⚠️"
              font.pixelSize: 13
            }

            Text {
              Layout.fillWidth: true
              text: root.selectionWarning
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              wrapMode: Text.Wrap
            }

            Text {
              text: "✕"
              color: root.muted
              font.pixelSize: 12
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectionWarning = ""
              }
            }
          }
        }

        // Limit lifecycle announcement — scrolls past like an old <marquee>,
        // for 30 seconds or until it is clicked away.
        Rectangle {
          id: eventBanner
          visible: root.activeEvent !== null
          Layout.fillWidth: true
          implicitHeight: Style.space(34)
          radius: root.radiusVal
          clip: true
          border.width: 1

          readonly property bool isReset: root.activeEvent !== null && root.activeEvent.kind === "reset"

          // Drives the rainbow band and the hue of a reset announcement.
          property real rainbow: 0
          NumberAnimation on rainbow {
            running: eventBanner.visible && eventBanner.isReset
            loops: Animation.Infinite
            from: 0
            to: 1
            duration: 2400
          }

          // Marquee travel: 0 = just off the right edge, 1 = just off the left.
          property real marquee: 0
          NumberAnimation on marquee {
            running: eventBanner.visible
            loops: Animation.Infinite
            from: 0
            to: 1
            duration: Math.max(4500, (eventBanner.width + marqueeText.implicitWidth) * 7)
          }

          color: eventBanner.isReset
            ? Qt.rgba(0, 0, 0, 0.35)
            : Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.15)
          border.color: eventBanner.isReset
            ? Qt.hsla(eventBanner.rainbow, 0.85, 0.6, 1.0)
            : root.urgent

          // Rainbow band sliding under a reset announcement. Two identical
          // colour cycles across double width, so the loop is seamless.
          Rectangle {
            visible: eventBanner.isReset
            height: parent.height
            width: parent.width * 2
            x: -parent.width * (1.0 - eventBanner.rainbow)
            opacity: 0.35

            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0.000; color: "#ff3b30" }
              GradientStop { position: 0.083; color: "#ff9500" }
              GradientStop { position: 0.167; color: "#ffcc00" }
              GradientStop { position: 0.250; color: "#34c759" }
              GradientStop { position: 0.333; color: "#32ade6" }
              GradientStop { position: 0.417; color: "#af52de" }
              GradientStop { position: 0.500; color: "#ff3b30" }
              GradientStop { position: 0.583; color: "#ff9500" }
              GradientStop { position: 0.667; color: "#ffcc00" }
              GradientStop { position: 0.750; color: "#34c759" }
              GradientStop { position: 0.833; color: "#32ade6" }
              GradientStop { position: 0.917; color: "#af52de" }
              GradientStop { position: 1.000; color: "#ff3b30" }
            }
          }

          // Depleted announcements pulse instead.
          Rectangle {
            anchors.fill: parent
            visible: !eventBanner.isReset && eventBanner.visible
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.25)

            SequentialAnimation on opacity {
              running: !eventBanner.isReset && eventBanner.visible
              loops: Animation.Infinite
              NumberAnimation { from: 0.0; to: 1.0; duration: 750; easing.type: Easing.InOutQuad }
              NumberAnimation { from: 1.0; to: 0.0; duration: 750; easing.type: Easing.InOutQuad }
            }
          }

          Item {
            id: marqueeClip
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: dismissButton.width + Style.space(14)
            clip: true

            Text {
              id: marqueeText
              anchors.verticalCenter: parent.verticalCenter
              x: marqueeClip.width - eventBanner.marquee * (marqueeClip.width + implicitWidth)
              text: root.activeEvent ? root.activeEvent.text : ""
              color: eventBanner.isReset
                ? Qt.hsla(1.0 - eventBanner.rainbow, 0.95, 0.75, 1.0)
                : root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }

          Rectangle {
            id: dismissButton
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: dismissLabel.implicitWidth + Style.space(12)
            implicitHeight: Style.space(20)
            radius: root.radiusVal
            color: root.background
            border.color: eventBanner.border.color

            Text {
              id: dismissLabel
              anchors.centerIn: parent
              text: root.eventQueue.length > 0 ? "✕ +" + root.eventQueue.length : "✕"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.dismissEvent()
          }
        }

        // Scrollable Tab Contents
        Flickable {
          id: flick
          Layout.fillWidth: true
          Layout.fillHeight: true
          contentWidth: width
          contentHeight: tabColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          ColumnLayout {
            id: tabColumn
            width: flick.width
            spacing: Style.space(12)

            // ==================== TAB 0: TRACKED IN DOCK ====================
            ColumnLayout {
              visible: root.activeTab === 0
              Layout.fillWidth: true
              spacing: Style.space(10)

              // Live Dock Preview Card
              Rectangle {
                Layout.fillWidth: true
                radius: root.radiusVal
                color: Qt.rgba(0, 0, 0, 0.4)
                border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.4)
                border.width: 1
                implicitHeight: previewCol.implicitHeight + Style.space(20)

                ColumnLayout {
                  id: previewCol
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  spacing: Style.space(6)

                  RowLayout {
                    Layout.fillWidth: true
                    Text {
                      text: "LIVE DOCK PREVIEW"
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                      text: root.barStyle.toUpperCase() + " • " + root.barLength + " CHARS"
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.2)
                  }

                  // ASCII Preview Lines
                  Column {
                    Layout.fillWidth: true
                    spacing: 4

                    Repeater {
                      model: root.trackedItems

                      Row {
                        spacing: 8
                        required property var modelData

                        Text {
                          visible: root.showLabel
                          text: modelData.shortLabel
                          color: root.coloredBars ? modelData.color : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: 11
                          font.bold: true
                        }

                        Text {
                          text: root.makeAsciiBar(modelData.percent, root.barLength, root.barStyle)
                          color: modelData.percent >= 0.95
                            ? root.urgent
                            : (root.coloredBars ? modelData.color : root.foreground)
                          font.family: root.fontFamily
                          font.pixelSize: 11
                        }

                        Text {
                          visible: root.showPercent
                          text: modelData.percentInt + "%"
                          color: modelData.percent >= 0.95 ? root.urgent : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: 11
                          font.bold: modelData.percent >= 0.95
                        }

                        Text {
                          visible: root.showReset && modelData.resetsFormatted !== ""
                          text: "(" + modelData.resetsFormatted + ")"
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: 10
                        }
                      }
                    }
                  }
                }
              }

              // Selector Section Header
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                Text {
                  text: "SELECT LIMITS TO TRACK IN DOCK:"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Item { Layout.fillWidth: true }

                FoldAllButton {}

                Rectangle {
                  implicitWidth: countBadgeText.implicitWidth + Style.space(14)
                  implicitHeight: Style.space(20)
                  radius: root.radiusVal
                  color: root.trackedCount >= 2 ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18) : root.cardBg
                  border.color: root.trackedCount >= 2 ? root.accent : root.cardBorder

                  Text {
                    id: countBadgeText
                    anchors.centerIn: parent
                    text: root.trackedCount + " / 2 selected" + (root.trackedCount >= 2 ? " (Max)" : "")
                    color: root.trackedCount >= 2 ? root.accent : root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: root.trackedCount >= 2
                  }
                }
              }

              // Limits grouped by provider, each provider in a collapsible panel
              Repeater {
                model: root.groupedLimits

                Rectangle {
                  id: groupCard
                  required property var modelData
                  readonly property bool expanded: !root.isProviderCollapsed(modelData.providerId)
                  readonly property int pinnedCount: root.trackedCountForProvider(modelData.providerId)
                  // The panel's first row, which is what the header reports for
                  // the provider — arrange the rows and you choose it.
                  readonly property var headLimit: modelData.topLimit || null

                  Layout.fillWidth: true
                  implicitHeight: groupCol.implicitHeight + Style.space(16)
                  radius: root.radiusVal
                  clip: true
                  color: root.cardBg
                  border.color: pinnedCount > 0
                    ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.55)
                    : root.cardBorder

                  ColumnLayout {
                    id: groupCol
                    anchors.fill: parent
                    anchors.margins: Style.space(8)
                    spacing: Style.space(6)

                    // Panel header — click anywhere to fold / unfold
                    Item {
                      Layout.fillWidth: true
                      implicitHeight: groupHeader.implicitHeight + Style.space(4)

                      RowLayout {
                        id: groupHeader
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(8)

                        Text {
                          text: "▸"
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          rotation: groupCard.expanded ? 90 : 0
                          Behavior on rotation {
                            NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
                          }
                        }

                        Rectangle {
                          width: 10
                          height: 10
                          radius: 5
                          color: groupCard.modelData.color
                        }

                        Text {
                          text: groupCard.modelData.providerName
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.bold: true
                        }

                        Text {
                          text: groupCard.modelData.limits.length === 1
                            ? "1 limit"
                            : groupCard.modelData.limits.length + " limits"
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }

                        Item { Layout.fillWidth: true }

                        // Header summary: the panel's TOP row. The limit the user
                        // put first is the one the provider is judged by, so the
                        // short label rides along — a bare bar would not say
                        // which of three limits is being reported.
                        Text {
                          visible: !groupCard.expanded && groupCard.headLimit !== null
                          text: groupCard.headLimit
                            ? groupCard.headLimit.shortLabel + "  "
                              + root.makeAsciiBar(groupCard.headLimit.percent, 10, root.barStyle)
                              + " " + groupCard.headLimit.percentInt + "%"
                            : ""
                          color: groupCard.headLimit && groupCard.headLimit.percent >= 0.95
                            ? root.urgent
                            : (root.coloredBars ? groupCard.modelData.color : root.foreground)
                          font.family: root.fontFamily
                          font.pixelSize: 10
                        }

                        Rectangle {
                          visible: groupCard.pinnedCount > 0
                          implicitWidth: pinnedBadge.implicitWidth + Style.space(10)
                          implicitHeight: Style.space(18)
                          radius: root.radiusVal
                          color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                          border.color: root.accent

                          Text {
                            id: pinnedBadge
                            anchors.centerIn: parent
                            text: "★ " + groupCard.pinnedCount + " in dock"
                            color: root.accent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                          }
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleProviderCollapsed(groupCard.modelData.providerId)
                      }
                    }

                    // Panel body — animates open / shut
                    Item {
                      id: groupBody
                      Layout.fillWidth: true
                      clip: true
                      implicitHeight: groupCard.expanded ? groupBodyCol.implicitHeight : 0
                      visible: implicitHeight > 0.5

                      Behavior on implicitHeight {
                        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                      }

                      ColumnLayout {
                        id: groupBodyCol
                        width: groupBody.width
                        spacing: Style.space(6)

                        Repeater {
                          model: groupCard.modelData.limits

                          Rectangle {
                            id: limitRow
                            required property var modelData
                            required property int index
                            readonly property bool canMoveUp: index > 0
                            readonly property bool canMoveDown: index < groupCard.modelData.limits.length - 1
                            Layout.fillWidth: true
                            implicitHeight: rowLayout.implicitHeight + Style.space(16)
                            radius: root.radiusVal
                            color: root.isLimitTracked(modelData.id)
                              ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
                              : (rowHover.containsMouse ? root.cardHover : root.cardBg)
                            border.color: root.isLimitTracked(modelData.id)
                              ? root.accent
                              : root.cardBorder
                            border.width: root.isLimitTracked(modelData.id) ? 1.5 : 1

                            RowLayout {
                              id: rowLayout
                              anchors.fill: parent
                              anchors.margins: Style.space(10)
                              spacing: Style.space(10)
                              // Above `rowHover`, which fills the row and is
                              // declared after this. `z` only orders siblings, so
                              // raising it on the arrows themselves would not lift
                              // them out from under that click area — it has to be
                              // set here, on their ancestor. Nothing else in this
                              // layout handles the mouse, so a click on the label
                              // or the bar still falls through and pins the limit.
                              z: 1

                              // Track Checkbox
                              Rectangle {
                                width: Style.space(20)
                                height: Style.space(20)
                                radius: root.radiusVal
                                color: root.isLimitTracked(modelData.id) ? root.accent : "transparent"
                                border.color: root.isLimitTracked(modelData.id) ? root.accent : root.muted
                                border.width: 1.5

                                Text {
                                  anchors.centerIn: parent
                                  text: "✓"
                                  color: "#000000"
                                  font.bold: true
                                  font.pixelSize: 12
                                  visible: root.isLimitTracked(modelData.id)
                                }
                              }

                              ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 3

                                RowLayout {
                                  spacing: 6
                                  Text {
                                    text: modelData.providerName + " — " + modelData.title
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.bodySmall
                                    font.bold: true
                                  }
                                  Item { Layout.fillWidth: true }
                                  Text {
                                    text: modelData.percentInt + "%"
                                    color: modelData.percent >= 0.95 ? root.urgent : (root.coloredBars ? modelData.color : root.foreground)
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.bodySmall
                                    font.bold: true
                                  }
                                }

                                // Progress bar preview
                                Text {
                                  text: root.makeAsciiBar(modelData.percent, 18, root.barStyle)
                                  color: modelData.percent >= 0.95 ? root.urgent : (root.coloredBars ? modelData.color : root.foreground)
                                  font.family: root.fontFamily
                                  font.pixelSize: 10
                                }

                                RowLayout {
                                  spacing: 8
                                  Text {
                                    visible: modelData.resetsFormatted !== ""
                                    text: "⏳ " + modelData.resetsFormatted
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                  }
                                  Text {
                                    visible: modelData.used !== null && modelData.allowance !== null
                                    text: "• " + modelData.used + " / " + modelData.allowance + " used"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                  }
                                }
                              }

                              // Arrange the panel. A blocked direction dims but
                              // stays put — both arrows keep their place so they
                              // do not jump about as a row travels — and keeps a
                              // live MouseArea, so the dead click is swallowed
                              // here rather than falling through and pinning the
                              // limit the user was only trying to move.
                              // `moveLimit` is what refuses the move itself.
                              ColumnLayout {
                                spacing: 2

                                Rectangle {
                                  readonly property bool armed: limitRow.canMoveUp
                                  readonly property bool lit: armed && moveUpArea.containsMouse
                                  implicitWidth: Style.space(18)
                                  implicitHeight: Style.space(15)
                                  radius: root.radiusVal
                                  opacity: armed ? 1.0 : 0.25
                                  color: lit ? root.cardHover : "transparent"
                                  border.color: lit ? root.accent : root.cardBorder

                                  Text {
                                    anchors.centerIn: parent
                                    text: "▲"
                                    color: parent.lit ? root.accent : root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: 8
                                  }

                                  MouseArea {
                                    id: moveUpArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: parent.armed ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: root.moveLimit(limitRow.modelData.providerId,
                                                              limitRow.modelData.id, -1)
                                  }
                                }

                                Rectangle {
                                  readonly property bool armed: limitRow.canMoveDown
                                  readonly property bool lit: armed && moveDownArea.containsMouse
                                  implicitWidth: Style.space(18)
                                  implicitHeight: Style.space(15)
                                  radius: root.radiusVal
                                  opacity: armed ? 1.0 : 0.25
                                  color: lit ? root.cardHover : "transparent"
                                  border.color: lit ? root.accent : root.cardBorder

                                  Text {
                                    anchors.centerIn: parent
                                    text: "▼"
                                    color: parent.lit ? root.accent : root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: 8
                                  }

                                  MouseArea {
                                    id: moveDownArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: parent.armed ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: root.moveLimit(limitRow.modelData.providerId,
                                                              limitRow.modelData.id, 1)
                                  }
                                }
                              }
                            }

                            // Marks the row that speaks for the provider when the
                            // panel is folded — the arrows are only meaningful if
                            // you can see what reaching the top buys you. Inset
                            // from the corners so it reads as a marker rather than
                            // a broken border on the row's rounded edge.
                            Rectangle {
                              visible: limitRow.index === 0 && groupCard.modelData.limits.length > 1
                              anchors.left: parent.left
                              anchors.leftMargin: 1
                              anchors.verticalCenter: parent.verticalCenter
                              width: 2
                              height: Math.max(0, parent.height - Style.space(14))
                              radius: 1
                              color: root.coloredBars ? groupCard.modelData.color : root.accent
                            }

                            MouseArea {
                              id: rowHover
                              anchors.fill: parent
                              hoverEnabled: true
                              cursorShape: Qt.PointingHandCursor
                              onClicked: root.toggleTrackLimit(modelData.id)
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }

            // ==================== TAB 1: ALL PROVIDERS ====================
            ColumnLayout {
              visible: root.activeTab === 1
              Layout.fillWidth: true
              spacing: Style.space(12)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                Text {
                  text: "PROVIDERS DETECTED:"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Item { Layout.fillWidth: true }

                FoldAllButton {}
              }

              Repeater {
                model: root.providers

                Rectangle {
                  id: provCard
                  required property var modelData
                  readonly property bool expanded: !root.isProviderCollapsed(modelData.id)
                  readonly property int pinnedCount: root.trackedCountForProvider(modelData.id)
                  readonly property real peakPercent: root.peakPercentOf(modelData.limits)

                  Layout.fillWidth: true
                  implicitHeight: provCardCol.implicitHeight + Style.space(20)
                  radius: root.radiusVal
                  clip: true
                  color: root.cardBg
                  border.color: root.cardBorder

                  ColumnLayout {
                    id: provCardCol
                    anchors.fill: parent
                    anchors.margins: Style.space(12)
                    spacing: Style.space(8)

                    // Provider Header — click anywhere to fold / unfold
                    Item {
                      Layout.fillWidth: true
                      implicitHeight: provHeader.implicitHeight + Style.space(4)

                      RowLayout {
                        id: provHeader
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        Text {
                          text: "▸"
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          rotation: provCard.expanded ? 90 : 0
                          Behavior on rotation {
                            NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
                          }
                        }

                        Rectangle {
                          width: 10
                          height: 10
                          radius: 5
                          color: provCard.modelData.color
                        }

                        Text {
                          text: provCard.modelData.name
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.subtitle
                          font.bold: true
                        }

                        Text {
                          visible: provCard.modelData.tierLabel !== ""
                          text: "(" + provCard.modelData.tierLabel + ")"
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }

                        Item { Layout.fillWidth: true }

                        // Header summary: the same headline limit the Dock Tracker
                        // panel reports, so a provider reads identically on both
                        // tabs. Falls back to peak usage for a provider whose
                        // limits never reached the grouping (none tracked yet).
                        Text {
                          readonly property var head: root.headLimitOf(provCard.modelData.id)
                          visible: !provCard.expanded && provCard.modelData.limitsCount > 0
                          text: head
                            ? head.shortLabel + "  "
                              + root.makeAsciiBar(head.percent, 10, root.barStyle)
                              + " " + head.percentInt + "%"
                            : root.makeAsciiBar(provCard.peakPercent, 10, root.barStyle)
                              + " " + Math.round(provCard.peakPercent * 100) + "%"
                          color: (head ? head.percent : provCard.peakPercent) >= 0.95
                            ? root.urgent
                            : (root.coloredBars ? provCard.modelData.color : root.foreground)
                          font.family: root.fontFamily
                          font.pixelSize: 10
                        }

                        Rectangle {
                          visible: provCard.pinnedCount > 0
                          implicitWidth: provPinnedBadge.implicitWidth + Style.space(10)
                          implicitHeight: Style.space(18)
                          radius: root.radiusVal
                          color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                          border.color: root.accent

                          Text {
                            id: provPinnedBadge
                            anchors.centerIn: parent
                            text: "★ " + provCard.pinnedCount + " in dock"
                            color: root.accent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                          }
                        }

                        Text {
                          text: provCard.modelData.limitsCount === 0
                            ? "No limits configured"
                            : (provCard.modelData.limitsCount === 1
                              ? "1 limit active"
                              : provCard.modelData.limitsCount + " limits active")
                          color: provCard.modelData.limitsCount > 0 ? root.accent : root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleProviderCollapsed(provCard.modelData.id)
                      }
                    }

                    // Panel body — animates open / shut
                    Item {
                      id: provBody
                      Layout.fillWidth: true
                      clip: true
                      implicitHeight: provCard.expanded ? provBodyCol.implicitHeight : 0
                      visible: implicitHeight > 0.5

                      Behavior on implicitHeight {
                        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                      }

                      ColumnLayout {
                        id: provBodyCol
                        width: provBody.width
                        spacing: Style.space(8)

                        // Auth text if unavailable
                        Text {
                          visible: modelData.authHelpText !== "" && modelData.limitsCount === 0
                          text: modelData.authHelpText
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          wrapMode: Text.WordWrap
                          Layout.fillWidth: true
                        }

                        // Provider Limits List
                        Repeater {
                          model: modelData.limits

                          Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: pLimCol.implicitHeight + Style.space(12)
                            radius: root.radiusVal
                            color: root.cardHover

                            ColumnLayout {
                              id: pLimCol
                              anchors.fill: parent
                              anchors.margins: Style.space(8)
                              spacing: 4

                              RowLayout {
                                Layout.fillWidth: true
                                Text {
                                  text: modelData.title
                                  color: root.foreground
                                  font.family: root.fontFamily
                                  font.pixelSize: Style.font.bodySmall
                                  font.bold: true
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                  text: modelData.percentInt + "%"
                                  color: modelData.percent >= 0.95 ? root.urgent : (root.coloredBars ? modelData.color : root.foreground)
                                  font.family: root.fontFamily
                                  font.pixelSize: Style.font.bodySmall
                                  font.bold: true
                                }
                              }

                              Text {
                                text: root.makeAsciiBar(modelData.percent, 22, root.barStyle)
                                color: modelData.percent >= 0.95 ? root.urgent : (root.coloredBars ? modelData.color : root.foreground)
                                font.family: root.fontFamily
                                font.pixelSize: 11
                              }

                              RowLayout {
                                Layout.fillWidth: true
                                Text {
                                  visible: modelData.resetsFormatted !== ""
                                  text: modelData.resetsFormatted
                                  color: root.muted
                                  font.family: root.fontFamily
                                  font.pixelSize: Style.font.caption
                                }
                                Item { Layout.fillWidth: true }
                                // Quick Pin Button
                                Rectangle {
                                  width: Style.space(90)
                                  height: Style.space(22)
                                  radius: root.radiusVal
                                  color: root.isLimitTracked(modelData.id) ? root.accent : root.cardBg
                                  border.color: root.accent

                                  Text {
                                    anchors.centerIn: parent
                                    text: root.isLimitTracked(modelData.id) ? "★ In Dock" : "+ Track"
                                    color: root.isLimitTracked(modelData.id) ? "#000000" : root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: 10
                                    font.bold: true
                                  }

                                  MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.toggleTrackLimit(modelData.id)
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }

            // ==================== TAB 2: STYLE & OPTIONS ====================
            ColumnLayout {
              visible: root.activeTab === 2
              Layout.fillWidth: true
              spacing: Style.space(12)

              Text {
                text: "ASCII PROGRESS BAR STYLE:"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              // Style buttons
              GridLayout {
                columns: 2
                Layout.fillWidth: true
                rowSpacing: 6
                columnSpacing: 6

                Repeater {
                  model: [
                    { id: "blocks", name: "Solid Blocks", sample: "[████░░░░]" },
                    { id: "shaded", name: "Retro Shaded", sample: "[▓▓▓▓░░░░]" },
                    { id: "ascii", name: "Classic ASCII", sample: "[====>   ]" },
                    { id: "retro", name: "Retro Hash", sample: "[####----]" },
                    { id: "squares", name: "LCD Squares", sample: "[■■■■□□□□]" },
                    { id: "braille", name: "Slim Braille", sample: "[⣿⣿⣿⣿⣀⣀⣀⣀]" }
                  ]

                  Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    height: Style.space(42)
                    radius: root.radiusVal
                    color: root.barStyle === modelData.id
                      ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                      : root.cardBg
                    border.color: root.barStyle === modelData.id ? root.accent : root.cardBorder
                    border.width: root.barStyle === modelData.id ? 1.5 : 1

                    ColumnLayout {
                      anchors.centerIn: parent
                      spacing: 2
                      Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: modelData.name
                        color: root.barStyle === modelData.id ? root.accent : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                      Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: modelData.sample
                        color: root.barStyle === modelData.id ? root.accent : root.muted
                        font.family: root.fontFamily
                        font.pixelSize: 10
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.saveSetting("barStyle", modelData.id)
                    }
                  }
                }
              }

              // Bar Length Selector
              Text {
                text: "PROGRESS BAR LENGTH (CHARACTERS):"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Repeater {
                  model: [10, 14, 16, 20, 24, 28]

                  Rectangle {
                    required property int modelData
                    Layout.fillWidth: true
                    height: Style.space(32)
                    radius: root.radiusVal
                    color: root.barLength === modelData ? root.accent : root.cardBg
                    border.color: root.cardBorder

                    Text {
                      anchors.centerIn: parent
                      text: modelData + " ch"
                      color: root.barLength === modelData ? "#000000" : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.saveSetting("barLength", modelData)
                    }
                  }
                }
              }

              // Refresh Interval Selector
              Text {
                text: "STATUS BAR REFRESH INTERVAL:"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Repeater {
                  model: [
                    { sec: 30, label: "30s" },
                    { sec: 60, label: "1m" },
                    { sec: 120, label: "2m" },
                    { sec: 300, label: "5m" },
                    { sec: 600, label: "10m" }
                  ]

                  Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    height: Style.space(32)
                    radius: root.radiusVal
                    color: root.refreshIntervalSec === modelData.sec ? root.accent : root.cardBg
                    border.color: root.cardBorder

                    Text {
                      anchors.centerIn: parent
                      text: modelData.label
                      color: root.refreshIntervalSec === modelData.sec ? "#000000" : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.saveSetting("refreshIntervalSec", modelData.sec)
                    }
                  }
                }
              }

              // Toggles
              Text {
                text: "DOCK DISPLAY TOGGLES:"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                // Show Label Toggle
                Rectangle {
                  Layout.fillWidth: true
                  height: Style.space(36)
                  radius: root.radiusVal
                  color: root.cardBg
                  border.color: root.cardBorder

                  RowLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(8)

                    Text {
                      text: "Show Provider Short Label (e.g. Claude 5h)"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                      text: root.showLabel ? "[ ON ]" : "[ OFF ]"
                      color: root.showLabel ? root.accent : root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.saveSetting("showLabel", !root.showLabel)
                  }
                }

                // Show Percentage Toggle
                Rectangle {
                  Layout.fillWidth: true
                  height: Style.space(36)
                  radius: root.radiusVal
                  color: root.cardBg
                  border.color: root.cardBorder

                  RowLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(8)

                    Text {
                      text: "Show Percentage (e.g. 82%)"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                      text: root.showPercent ? "[ ON ]" : "[ OFF ]"
                      color: root.showPercent ? root.accent : root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.saveSetting("showPercent", !root.showPercent)
                  }
                }

                // Show Reset Countdown Toggle
                Rectangle {
                  Layout.fillWidth: true
                  height: Style.space(36)
                  radius: root.radiusVal
                  color: root.cardBg
                  border.color: root.cardBorder

                  RowLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(8)

                    Text {
                      text: "Show Reset Countdown (e.g. 2h55m)"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                      text: root.showReset ? "[ ON ]" : "[ OFF ]"
                      color: root.showReset ? root.accent : root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.saveSetting("showReset", !root.showReset)
                  }
                }

                // Colored Bars Toggle
                Rectangle {
                  Layout.fillWidth: true
                  height: Style.space(36)
                  radius: root.radiusVal
                  color: root.cardBg
                  border.color: root.cardBorder

                  RowLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(8)

                    Text {
                      text: "Use Provider Signature Colors"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                      text: root.coloredBars ? "[ ON ]" : "[ OFF ]"
                      color: root.coloredBars ? root.accent : root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.saveSetting("coloredBars", !root.coloredBars)
                  }
                }
              }

              Text {
                text: "SHORTCUTS & GESTURES:\n• Click dock widget: Open this panel\n• Right-click dock widget: Quick cycle ASCII style\n• Middle-click dock widget: Force immediate refresh\n• 'r' in panel: Refresh data | '1','2','3': Switch tabs | Esc: Close"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- IPC Handler
  IpcHandler {
    target: "gladimdim.ai-limits"

    function open(): string {
      root.open()
      return "ok"
    }

    function close(): string {
      root.close()
      return "ok"
    }

    function toggle(): string {
      root.toggle()
      return "ok"
    }

    function click(button: int): string {
      root.triggerPress(button)
      return "ok"
    }

    function refresh(): string {
      root.triggerRefresh(true)
      return "ok"
    }

    function nextStyle(): string {
      root.cycleStyle()
      return root.barStyle
    }

    function setStyle(style: string): string {
      var styles = ["blocks", "shaded", "ascii", "retro", "squares", "braille"]
      if (styles.indexOf(style) !== -1) {
        root.saveSetting("barStyle", style)
        return "ok: " + style
      }
      return "invalid style. available: " + styles.join(", ")
    }

    function toggleLimit(id: string): string {
      root.toggleTrackLimit(id)
      return "ok"
    }

    // Preview the announcement banner: kind is "depleted" or "reset".
    function demoEvent(kind: string): string {
      if (kind !== "depleted" && kind !== "reset") return "invalid kind. available: depleted, reset"
      var limits = root.allLimits
      var lim = limits && limits.length > 0 ? limits[0] : null
      root.pushLimitEvent(kind, lim)
      return "ok"
    }

    function debugInfo(): string {
      return JSON.stringify({
        scriptPath: root.scriptPath,
        procRunning: collectorProc.running,
        settings: root.settings,
        trackedSettings: root.trackedSettings,
        trackedCount: root.trackedItems.length,
        limitsCount: root.allLimits ? root.allLimits.length : -1,
        providersCount: root.providers ? root.providers.length : -1,
        trackedItems: root.trackedItems
      })
    }
  }
}
