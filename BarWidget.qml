pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar widget for SteelSeries mice: shows the active DPI and opens a panel for
// editing the preset table and polling rate.
//
// Nothing here knows which mouse is plugged in. `scripts/steelseries get`
// returns the device's capabilities alongside its state — the DPI range or the
// exact DPI values it accepts, how many presets it holds, whether the active
// one can be chosen at all — and this panel draws itself from that.
//
// Modern mice hold a table of presets and cycle them with the button behind
// the scroll wheel, reporting the press back to the host, so
// `steelseries-device watch` keeps this panel honest when you use the button
// instead of the panel. Older ones hold two fixed slots and say nothing. The
// device volunteers nothing on request either way, so before the first write
// or press the state is flagged `assumed`.
Panel {
  id: root
  moduleName: "io.github.dfrost90.steelseries-mice"
  ipcTarget: "io.github.dfrost90.steelseries-mice"

  readonly property string script: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/" + moduleName + "/scripts/steelseries"
  readonly property string deviceScript: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/" + moduleName + "/scripts/steelseries-device"

  property var presets: [800, 1600]
  property int selected: 0
  property int activeDpi: 800
  property int polling: 1000
  property bool assumed: true
  property bool connected: false
  property bool haveHelper: false
  property string lastError: ""
  property string appliedAt: ""
  property bool busy: false

  // Everything below is the connected device describing itself.
  property string deviceName: "SteelSeries mouse"
  property string mode: "table"
  property int dpiMin: 200
  property int dpiMax: 8500
  property int dpiStep: 100
  property var dpiValues: []
  property int presetMin: 1
  property int presetMax: 5
  property bool selectable: true
  property bool tracking: false
  property bool verified: false
  property var pollingOptions: ["125", "250", "500", "1000"]

  // Nothing may write to the mouse until we have read the state once.
  // Bindings settle as the panel builds — a ButtonGroup emits `changed` on
  // its way to the stored value — and an unguarded write turns that into a
  // hardware change the user never asked for.
  property bool ready: false

  // A table being scrolled, not yet sent. One notch of the wheel is one DPI
  // step, and a flick of the wheel is a dozen of them; writing each one would
  // hammer the device with tables nobody asked to keep. The chips show this
  // while it exists, so the number still moves under the cursor.
  property var pendingPresets: null
  readonly property var displayPresets: pendingPresets !== null ? pendingPresets : presets
  readonly property int displayDpi: selected < displayPresets.length
    ? displayPresets[selected] : activeDpi

  readonly property bool healthy: connected && haveHelper && lastError === ""
  readonly property bool editable: ready && healthy
  // A device with a fixed handful of DPI values takes nothing in between, so
  // those rows offer the values themselves rather than a stepper.
  readonly property bool discreteDpi: dpiValues.length > 0
  readonly property bool resizable: presetMax > presetMin

  readonly property color fg: bar ? bar.barForeground : Color.foreground
  readonly property color panelFg: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(panelFg, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  function run(args) {
    if (writeProc.running) return
    busy = true
    writeProc.command = [root.script].concat(args)
    writeProc.running = true
  }

  function presetCsv(list) {
    return list.join(",")
  }

  function selectPreset(index) {
    if (!editable || !selectable || index === root.selected) return
    root.selected = index
    root.activeDpi = root.presets[index]
    run(["select", String(index)])
  }

  // The next DPI one notch away, however this device counts them: along its
  // step for a range, or along its own list where only a handful are legal.
  function nextDpi(value, direction) {
    if (root.discreteDpi) {
      var at = root.dpiValues.indexOf(value)
      if (at < 0) return root.dpiValues[0]
      var moved = at + direction
      if (moved < 0 || moved >= root.dpiValues.length) return value
      return root.dpiValues[moved]
    }
    var stepped = value + direction * root.dpiStep
    return Math.max(root.dpiMin, Math.min(root.dpiMax, stepped))
  }

  function nudgePreset(index, direction) {
    if (!editable) return
    var next = root.displayPresets.slice()
    var moved = nextDpi(next[index], direction)
    if (moved === next[index]) return
    next[index] = moved
    root.pendingPresets = next
    commitTimer.restart()
  }

  function commitPending() {
    if (root.pendingPresets === null) return
    // A write is already in flight and `run` would drop this one on the floor,
    // leaving the panel showing a value the mouse never got.
    if (writeProc.running) {
      commitTimer.restart()
      return
    }
    var next = root.pendingPresets
    root.pendingPresets = null
    writePresets(next, root.selected)
  }

  function addPreset() {
    if (!editable || root.displayPresets.length >= root.presetMax) return
    var next = root.displayPresets.slice()
    next.push(next[next.length - 1])
    writePresets(next, root.selected)
  }

  function removePreset(index) {
    if (!editable || root.displayPresets.length <= root.presetMin) return
    var next = root.displayPresets.slice()
    next.splice(index, 1)
    // The table shrank under the selection; keep it inside the new bounds.
    var selection = root.selected >= next.length ? next.length - 1 : root.selected
    writePresets(next, selection)
  }

  function writePresets(list, selection) {
    // Whatever was being scrolled is part of this write or superseded by it.
    root.pendingPresets = null
    commitTimer.stop()
    root.presets = list
    root.selected = selection
    root.activeDpi = list[selection]
    run(["set", "--presets", presetCsv(list), "--selected", String(selection)])
  }

  function setPolling(value) {
    var next = parseInt(value, 10)
    if (!editable || !isFinite(next) || next === root.polling) return
    root.polling = next
    run(["set", "--polling", String(next)])
  }

  function applyState(text) {
    var state = null
    try { state = JSON.parse(text) } catch (e) { return }
    if (!state || !(state.presets instanceof Array)) return

    root.presets = state.presets
    root.selected = state.selected
    root.activeDpi = state.activeDpi
    root.polling = state.polling
    root.assumed = state.assumed === true
    root.connected = state.connected === true
    root.haveHelper = state.helper === true
    root.lastError = String(state.error || "")
    root.appliedAt = String(state.appliedAt || "")

    if (state.name) root.deviceName = String(state.name)
    if (state.mode) root.mode = String(state.mode)
    if (state.dpiMin > 0) root.dpiMin = state.dpiMin
    if (state.dpiMax > 0) root.dpiMax = state.dpiMax
    root.dpiStep = state.dpiStep > 0 ? state.dpiStep : 1
    root.dpiValues = state.dpiValues instanceof Array ? state.dpiValues : []
    if (state.presetMin > 0) root.presetMin = state.presetMin
    if (state.presetMax > 0) root.presetMax = state.presetMax
    root.selectable = state.selectable === true
    root.tracking = state.tracking === true
    root.verified = state.verified === true
    if (state.pollingOptions instanceof Array && state.pollingOptions.length > 0)
      root.pollingOptions = state.pollingOptions.map(String)

    root.ready = true
  }

  // A press of the physical DPI button arrives here as one JSON line.
  function observed(line) {
    var report = null
    try { report = JSON.parse(line) } catch (e) { return }
    if (!report || !(report.presets instanceof Array)) return

    // The device just told us what it holds, which outranks a half-finished
    // scroll of ours.
    root.pendingPresets = null
    commitTimer.stop()
    root.presets = report.presets
    root.selected = report.selected
    root.activeDpi = report.presets[report.selected] || report.presets[0]
    root.assumed = false
    // Persist it: the device is authoritative about its own table.
    run(["observe", String(report.selected), "--presets", presetCsv(report.presets)])
  }

  function statusLine() {
    if (!haveHelper) return "Device helper missing"
    if (!connected) return "No supported SteelSeries mouse connected"
    if (lastError !== "") return lastError
    if (assumed) return "Assumed — nothing applied or observed yet"
    if (!selectable) return displayPresets.length + " fixed DPI slots · switched on the mouse"
    return "Preset " + (selected + 1) + " of " + displayPresets.length
      + " · " + displayDpi + " DPI"
  }

  // Said plainly rather than hidden, because it is the one thing about this
  // panel that a user cannot check for themselves: on any mouse but the one it
  // was developed against, the writes are built from rivalcfg's profile and
  // have never been watched landing on real hardware.
  function caveatLine() {
    if (!connected || verified) return ""
    if (mode === "pair")
      return "Untested model. Fixed slots — the panel cannot follow the DPI button."
    if (!tracking)
      return "Untested model. Its report layout is unknown, so the DPI button is not followed."
    return "Untested model, driven from rivalcfg's profile."
  }

  // Shown under the section header rather than in a tooltip: right-click
  // removes a preset with no way back, so it should not need hovering to
  // discover. Only the invisible gestures are listed — a chip already looks
  // like a button, and a third line of hint costs more than it explains.
  function gestureHint() {
    var parts = ["Scroll to change"]
    if (resizable) parts.push("right-click to remove")
    return parts.join(" · ")
  }

  visible: connected
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    // Safe by construction: apply is a no-op unless a real table is stored.
    run(["apply"])
  }

  Process {
    id: stateProc
    command: [root.script, "get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyState(String(text || ""))
    }
  }

  Process {
    id: writeProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.lastError = message.replace(/^steelseries: /, "")
      }
    }
    onExited: {
      root.busy = false
      // The state file is authoritative for what actually landed, including
      // whichever error a failed write recorded.
      root.refresh()
    }
  }

  // Follows the physical DPI button for as long as the shell runs. The read
  // blocks in the helper, so this costs nothing while the button is idle, and
  // devices whose report layout we cannot decode never start it at all.
  Process {
    id: watchProc
    command: [root.deviceScript, "watch"]
    running: root.connected && root.tracking
    stdout: SplitParser {
      onRead: function(line) { root.observed(line) }
    }
  }

  // Sends the scrolled table once the wheel has been still for a moment.
  Timer {
    id: commitTimer
    interval: 350
    onTriggered: root.commitPending()
  }

  // The mouse can be plugged in after the shell starts, and nothing notifies
  // us. A slow poll is enough to make the widget appear on its own.
  Timer {
    interval: 10000
    running: !root.connected
    repeat: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍽 " + (root.selectable ? root.displayDpi : root.displayPresets.join("/"))
    active: root.opened
    dimmed: root.assumed
    tooltipText: root.deviceName + " · " + root.polling + " Hz"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Size to the content rather than a fixed width, with the old width
    // kept only as a ceiling so a long status line cannot stretch it.
    // contentWidth is the outer card width, and unlike fittedContentHeight the
    // width helper adds no inset of its own, so the padding and borders have
    // to be added here or the widest row gets clipped.
    contentWidth: popup.fittedContentWidth(
      column.implicitWidth + popup.padding * 2
        + Border.left(popup.borderSpec) + Border.right(popup.borderSpec),
      Style.space(420))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      // Never drawn: it exists so every chip can borrow one width.
      //
      // A Grid sizes each column to its widest cell and leaves narrower ones
      // sitting at the left of the gap, so a three-digit 800 beside a
      // four-digit 3200 pulls the rows out of line. Measuring the widest DPI
      // this device can hold — rather than the widest it currently holds —
      // also keeps the chips and the panel still while a value is scrolled
      // past a digit boundary. Borrowing a real Button rather than computing
      // from a font metric means the padding and border arithmetic stays
      // wherever Button keeps it.
      Button {
        id: chipSizer
        visible: false
        bordered: true
        text: String(root.dpiMax)
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.spacing.md

        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            id: title
            text: root.deviceName
            color: root.panelFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            anchors.baseline: title.baseline
            text: root.busy ? "applying…" : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          text: root.statusLine()
          color: root.healthy ? root.dim : root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: root.caveatLine()
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        PanelSeparator { width: parent.width; foreground: root.panelFg }

        PanelSectionHeader {
          text: root.selectable ? "DPI PRESETS" : "DPI SLOTS"
          foreground: root.panelFg
          fontFamily: root.fontFamily
        }

        Text {
          width: parent.width
          visible: root.editable
          text: root.gestureHint()
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        // One chip per preset, laid out like the polling row below: the
        // highlighted chip is the active preset, so the value and the marker
        // are the same object rather than a dot beside a spinbox.
        //
        // A Grid rather than a Row so a fourth and fifth preset wrap instead
        // of widening the panel. Three columns is the whole point: the panel
        // settles at one width and stays there whatever the table holds. A
        // Flow would wrap too, but its width would have to come from the
        // column that is itself sized by this content.
        Grid {
          columns: 3
          spacing: Style.spacing.md

          Repeater {
            model: root.displayPresets.length

            Button {
              id: chip
              required property int index
              readonly property int dpi: index < root.displayPresets.length
                ? root.displayPresets[index] : root.dpiMin
              // Wheels report in eighths of a degree and a notch is 120 of
              // them; a touchpad sends far smaller slices. Accumulating means
              // one notch is one step on either.
              property real wheelTravel: 0

              text: String(chip.dpi)
              width: chipSizer.implicitWidth
              bordered: true
              selected: root.selectable && index === root.selected
              foreground: root.panelFg
              background: root.bar ? root.bar.background : Color.background
              accent: Color.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.selectPreset(index)
              onRightClicked: root.removePreset(index)

              // A MouseArea, not a WheelHandler. Button fills itself with a
              // MouseArea, and one MouseArea will not yield the wheel to a
              // pointer handler underneath it however that handler is
              // stacked — a WheelHandler here is simply never reached.
              // acceptedButtons: Qt.NoButton leaves clicks to the Button.
              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton

                onWheel: function(wheel) {
                  if (!root.editable)
                    return
                  // Horizontal wheels and touchpad side-scrolls report
                  // y === 0; without this every one would read as a step up.
                  if (wheel.angleDelta.y === 0)
                    return
                  chip.wheelTravel += wheel.angleDelta.y
                  while (chip.wheelTravel >= 120) {
                    chip.wheelTravel -= 120
                    root.nudgePreset(chip.index, 1)
                  }
                  while (chip.wheelTravel <= -120) {
                    chip.wheelTravel += 120
                    root.nudgePreset(chip.index, -1)
                  }
                }
              }
            }
          }
        }

        Button {
          visible: root.resizable && root.displayPresets.length < root.presetMax
          text: "+ add preset"
          foreground: root.panelFg
          accent: Color.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: root.addPreset()
        }

        PanelSeparator { width: parent.width; foreground: root.panelFg }

        PanelSectionHeader {
          text: "POLLING RATE (HZ)"
          foreground: root.panelFg
          fontFamily: root.fontFamily
        }

        ButtonGroup {
          options: root.pollingOptions
          value: String(root.polling)
          foreground: root.panelFg
          background: root.bar ? root.bar.background : Color.background
          accent: Color.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          focusable: false

          onChanged: function(value) { root.setPolling(value) }
        }
      }
    }
  }
}
