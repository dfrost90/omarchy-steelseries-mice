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
  moduleName: "omarchyplugins.steelseries"
  ipcTarget: "omarchyplugins.steelseries"

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

  function setPresetValue(index, value) {
    if (!editable) return
    var next = root.presets.slice()
    if (next[index] === value) return
    next[index] = value
    writePresets(next, root.selected)
  }

  function addPreset() {
    if (!editable || root.presets.length >= root.presetMax) return
    var next = root.presets.slice()
    next.push(next[next.length - 1])
    writePresets(next, root.selected)
  }

  function removePreset(index) {
    if (!editable || root.presets.length <= root.presetMin) return
    var next = root.presets.slice()
    next.splice(index, 1)
    // The table shrank under the selection; keep it inside the new bounds.
    var selection = root.selected >= next.length ? next.length - 1 : root.selected
    writePresets(next, selection)
  }

  function writePresets(list, selection) {
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
    if (!selectable) return presets.length + " fixed DPI slots · switched on the mouse"
    return "Preset " + (selected + 1) + " of " + presets.length + " · " + activeDpi + " DPI"
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
    text: "󰍽 " + (root.selectable ? root.activeDpi : root.presets.join("/"))
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
      Style.space(320))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

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

        Repeater {
          model: root.presets.length

          Row {
            id: presetRow
            required property int index

            width: column.width
            spacing: Style.spacing.controlGap

            // Click the marker to make this preset the active one — the same
            // thing the button behind the scroll wheel does. Devices that
            // cannot be told which slot is live get a plain number instead of
            // a control that would do nothing.
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(18)
              text: root.selectable
                ? (presetRow.index === root.selected ? "●" : "○")
                : String(presetRow.index + 1)
              color: root.selectable && presetRow.index === root.selected
                ? root.panelFg : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                enabled: root.editable && root.selectable
                onClicked: root.selectPreset(presetRow.index)
              }
            }

            NumberField {
              anchors.verticalCenter: parent.verticalCenter
              visible: !root.discreteDpi
              value: presetRow.index < root.presets.length
                ? root.presets[presetRow.index] : root.dpiMin
              from: root.dpiMin
              to: root.dpiMax
              stepSize: root.dpiStep
              foreground: root.panelFg
              accent: Color.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              // SpinBox formats through its locale, which groups thousands:
              // "1,200" reads as two values rather than one DPI figure.
              Component.onCompleted: field.locale = Qt.locale("C")
              onModified: function(value) { root.setPresetValue(presetRow.index, value) }
            }

            ButtonGroup {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.discreteDpi
              options: root.dpiValues.map(String)
              value: presetRow.index < root.presets.length
                ? String(root.presets[presetRow.index]) : ""
              foreground: root.panelFg
              background: root.bar ? root.bar.background : Color.background
              accent: Color.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              focusable: false

              onChanged: function(value) {
                root.setPresetValue(presetRow.index, parseInt(value, 10))
              }
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.presets.length > root.presetMin
              iconText: "×"
              tooltipText: "Remove this preset"
              foreground: root.panelFg
              accent: Color.accent
              fontFamily: root.fontFamily
              onClicked: root.removePreset(presetRow.index)
            }
          }
        }

        Button {
          visible: root.resizable && root.presets.length < root.presetMax
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
