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

  property bool popupOpen: false
  property int activeTab: 0 // 0: Dock Tracker, 1: All Providers, 2: Style & Options
  property bool refreshing: false
  property string statusMessage: ""
  property double nowMs: Date.now()

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

  // Settings from shell.json
  readonly property var trackedSettings: setting("tracked", ["claude:session-5-hour", "grok:weekly"])
  readonly property int barLength: Math.max(8, Math.min(32, Number(setting("barLength", 16))))
  readonly property string barStyle: String(setting("barStyle", "blocks"))
  readonly property bool showPercent: Boolean(setting("showPercent", true))
  readonly property bool showReset: Boolean(setting("showReset", true))
  readonly property bool showLabel: Boolean(setting("showLabel", true))
  readonly property bool coloredBars: Boolean(setting("coloredBars", true))
  readonly property int refreshIntervalSec: Math.max(10, Number(setting("refreshIntervalSec", 60)))

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
    var trackedList = Array.isArray(trackedSettings) ? trackedSettings : []
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

    trackedItems = result
  }

  onLimitsDataChanged: updateTrackedItems()
  onAllLimitsChanged: updateTrackedItems()
  onTrackedSettingsChanged: updateTrackedItems()

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
    var trackedList = Array.isArray(trackedSettings) ? trackedSettings : []
    return trackedList.indexOf(limitId) !== -1
  }

  function toggleTrackLimit(limitId) {
    var trackedList = Array.isArray(trackedSettings) ? trackedSettings.slice() : []
    var idx = trackedList.indexOf(limitId)

    if (idx !== -1) {
      trackedList.splice(idx, 1)
    } else {
      if (trackedList.length >= 2) {
        // Keep at most 2: drop the oldest and append the new one
        trackedList.shift()
      }
      trackedList.push(limitId)
    }

    saveSetting("tracked", trackedList)
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
    if (collectorProc.running) return
    root.refreshing = true
    collectorProc.command = force === true
      ? ["python3", root.scriptPath, "--refresh"]
      : ["python3", root.scriptPath]
    collectorProc.running = true
  }

  function applyData(rawText) {
    root.refreshing = false
    var raw = String(rawText || "").trim()
    if (raw === "") return
    try {
      var parsed = JSON.parse(raw)
      if (parsed && (parsed.providers || parsed.allLimits)) {
        root.limitsData = parsed
        root.nowMs = Date.now()
        root.updateTrackedItems()
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
      root.refreshing = false
    }
  }

  Timer {
    id: autoRefreshTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.triggerRefresh(false)
  }

  Timer {
    interval: 5000
    running: root.popupOpen
    repeat: true
    onTriggered: root.triggerRefresh(false)
  }

  Component.onCompleted: {
    root.triggerRefresh(false)
  }

  function tooltipContent() {
    var items = trackedItems
    if (!items || items.length === 0) return "AI Limits Tracker\n(Click to configure)"
    var lines = ["AI Limits Tracker (Click for details)"]
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      var rText = item.resetsFormatted ? " (" + item.resetsFormatted + ")" : ""
      lines.push("• " + item.providerName + " " + item.title + ": " + item.percentInt + "%" + rText)
    }
    return lines.join("\n")
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
    popupOpen = !popupOpen
    if (popupOpen) triggerRefresh(false)
  }

  // ------------------------------------------------------------- Dock Bar UI
  implicitWidth: dockItem.implicitWidth
  implicitHeight: root.barSize

  Item {
    id: dockItem
    anchors.fill: parent
    implicitWidth: Math.max(36, dockContent.implicitWidth + Style.space(16))
    implicitHeight: root.barSize

    property var registeredBar: null
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

    // Centered Dock Content
    Item {
      id: dockContent
      anchors.centerIn: parent
      implicitWidth: root.trackedItems.length === 1 ? singleRow.implicitWidth : multiColumn.implicitWidth
      implicitHeight: root.trackedItems.length === 1 ? singleRow.implicitHeight : multiColumn.implicitHeight

      // Fallback if no limits found
      Text {
        visible: root.trackedItems.length === 0
        anchors.centerIn: parent
        text: "[ AI Limits ]"
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
          color: root.coloredBars && singleRow.item ? singleRow.item.color : root.foreground
          font.family: root.fontFamily
          font.pixelSize: 10
          font.bold: true
          renderType: Text.NativeRendering
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          visible: singleRow.item !== null
          text: singleRow.item ? root.makeAsciiBar(singleRow.item.percent, root.barLength, root.barStyle) : ""
          color: singleRow.item && singleRow.item.percent >= 0.95
            ? root.urgent
            : (root.coloredBars && singleRow.item ? singleRow.item.color : root.foreground)
          font.family: root.fontFamily
          font.pixelSize: 10
          renderType: Text.NativeRendering
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          visible: root.showPercent && singleRow.item !== null
          text: singleRow.item ? singleRow.item.percentInt + "%" : ""
          color: singleRow.item && singleRow.item.percent >= 0.95 ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: 10
          font.bold: singleRow.item && singleRow.item.percent >= 0.95
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
                  color: root.coloredBars ? modelData.color : root.foreground
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
                text: root.makeAsciiBar(modelData.percent, root.barLength, root.barStyle)
                color: modelData.percent >= 0.95
                  ? root.urgent
                  : (root.coloredBars ? modelData.color : root.foreground)
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
                  color: modelData.percent >= 0.95 ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: 9
                  font.bold: modelData.percent >= 0.95
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

  // ------------------------------------------------------------- Popup Dialog
  KeyboardPanel {
    id: panel
    anchorItem: dockItem
    owner: root
    bar: root.bar
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(Style.space(540), Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.popupOpen = false
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.triggerRefresh(true)
        if (t === "1") root.activeTab = 0
        if (t === "2") root.activeTab = 1
        if (t === "3") root.activeTab = 2
        if (t === "c" || t === "C") root.cycleStyle()
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
              text: "AI Limits & Quotas"
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
              onClicked: root.popupOpen = false
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

              // Selector Section
              Text {
                text: "SELECT LIMITS TO TRACK IN DOCK (UP TO 2):"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              // List of all limits for user to toggle
              Repeater {
                model: root.allLimits

                Rectangle {
                  id: limitRow
                  required property var modelData
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

            // ==================== TAB 1: ALL PROVIDERS ====================
            ColumnLayout {
              visible: root.activeTab === 1
              Layout.fillWidth: true
              spacing: Style.space(12)

              Repeater {
                model: root.providers

                Rectangle {
                  id: provCard
                  required property var modelData
                  Layout.fillWidth: true
                  implicitHeight: provCardCol.implicitHeight + Style.space(20)
                  radius: root.radiusVal
                  color: root.cardBg
                  border.color: root.cardBorder

                  ColumnLayout {
                    id: provCardCol
                    anchors.fill: parent
                    anchors.margins: Style.space(12)
                    spacing: Style.space(8)

                    // Provider Header
                    RowLayout {
                      Layout.fillWidth: true
                      spacing: 8

                      Rectangle {
                        width: 10
                        height: 10
                        radius: 5
                        color: modelData.color
                      }

                      Text {
                        text: modelData.name
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                      }

                      Text {
                        visible: modelData.tierLabel !== ""
                        text: "(" + modelData.tierLabel + ")"
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Item { Layout.fillWidth: true }

                      Text {
                        text: modelData.limitsCount > 0 ? modelData.limitsCount + " limits active" : "No limits configured"
                        color: modelData.limitsCount > 0 ? root.accent : root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

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
      root.popupOpen = true
      root.triggerRefresh(false)
      return "ok"
    }

    function close(): string {
      root.popupOpen = false
      return "ok"
    }

    function toggle(): string {
      root.popupOpen = !root.popupOpen
      if (root.popupOpen) root.triggerRefresh(false)
      return "ok"
    }

    function refresh(): string {
      root.triggerRefresh(true)
      return "ok"
    }

    function debugInfo(): string {
      return JSON.stringify({
        scriptPath: root.scriptPath,
        procRunning: collectorProc.running,
        trackedSettings: root.trackedSettings,
        trackedCount: root.trackedItems.length,
        limitsCount: root.allLimits ? root.allLimits.length : -1,
        providersCount: root.providers ? root.providers.length : -1,
        trackedItems: root.trackedItems
      })
    }
  }
}
