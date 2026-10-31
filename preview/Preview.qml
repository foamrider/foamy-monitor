import QtQuick
import "../kit"
import ".." as Monitor

// Mock states for the foamy-kit preview harness (no processes: MonitorService
// stays inactive without a bar panel, and the mock sets its state directly).
// The harness sets bar/anchorItem, then cycles previewState and captures `popup`.
Item {
  id: preview
  required property QtObject bar
  required property Item anchorItem
  property var previewStates: ["display", "trial", "advanced", "wireless", "wireless-scanning", "wireless-refreshing", "wireless-missing", "loading"]
  property string previewState: "display"
  property int settleMs: 700
  readonly property Item popup: popup
  readonly property var service: Monitor.MonitorService

  function display(name, description, x, width, height, scale, focused) {
    var modes = [width + "x" + height + "@60.00Hz", width + "x" + height + "@120.00Hz", "1920x1080@60.00Hz"]
    return { id: description ? "desc:" + description : name, selector: description ? "desc:" + description : name, name: name,
      description: description, make: description ? description.split(" ")[0] : "BOE", model: description ? description.split(" ")[1] : "0x0BCA",
      serial: "", width: width, height: height, refreshRate: 60, scale: scale, transform: 0, x: x, y: 0,
      disabled: false, focused: focused, mirrorOf: "", connected: true, availableModes: modes }
  }
  readonly property var live: [
    display("eDP-1", "", 0, 2880, 1800, 1.6, true),
    display("DP-1", "LG Electronics LG ULTRAFINE", 1800, 3840, 2160, 1.5, false),
    display("HDMI-A-1", "Dell Inc. DELL U2720Q", 4360, 1920, 1080, 1, false)
  ]

  QtObject {
    id: mockHost
    property QtObject bar: preview.bar
    readonly property bool opened: true
    function close() {}
    function switchPanel(direction) { return false }
  }

  function apply() {
    var state = previewState
    var draft = live.map(function(m) { return Object.assign({}, m) })
    if (state === "display") { draft[1].x = 1900; draft[1].scale = 2 }
    var loading = state === "loading"
    service.transaction = loading ? { phase: "idle", base: [], draft: [] } : {
      phase: state === "trial" ? "testing" : "idle", base: live, draft: state === "trial" ? live : draft,
      deadline: Date.now() / 1000 + 11, token: "preview", revision: 3, error: ""
    }
    service.liveMonitors = loading ? [] : live
    service.gtkScale = { base: 2, value: 2, error: "" }
    service.brightness = { "eDP-1": { available: true, percent: 64 } }
    service.cursorSize = 24
    // wireless-scanning: a first scan (searching row); wireless-refreshing: the
    // cached list on reopen while it refreshes (only the Scan glyph turns).
    var listed = state === "wireless" || state === "wireless-refreshing"
    service.wirelessPeers = listed ? [{ address: "7A:2D:91:40:0B:CE", name: "Living Room TV" }, { address: "02:11:22:33:44:55", name: "" }] : []
    // A recent scan, so showing the tab keeps the list (the TTL would discard it).
    service.wirelessScannedAt = listed ? Date.now() - 30000 : 0
    service.previewScanning = state === "wireless-scanning" || state === "wireless-refreshing"
    service.wirelessScanState = service.previewScanning ? "scanning" : state === "wireless" ? "results" : state === "wireless-missing" ? "missing" : "idle"
    service.missingPackages = state === "wireless-missing" ? ["fluxcast-git"] : []
    service.wirelessError = state === "wireless-missing" ? "Please install fluxcast-git" : ""
    var view = popup.bodyItem
    if (!view) return
    view.selectedMonitor = loading ? "" : live[0].id
    view.activeTab = state === "advanced" ? "Advanced" : state.indexOf("wireless") === 0 ? "Wireless" : "Display"
    view.now = Date.now()
    if (state === "display") view.place("resolution")
    else if (state === "wireless") view.place("peer:0")
    else if (state === "wireless-scanning" || state === "wireless-refreshing") view.place("scan")
    else if (state === "trial") view.place("revert")
    else view.place("")
  }
  onPreviewStateChanged: Qt.callLater(apply)

  FoamyPopup {
    id: popup
    anchorItem: preview.anchorItem
    bar: preview.bar
    open: true
    wide: true
    body: Component {
      Monitor.MonitorView { host: mockHost }
    }
    onBodyItemChanged: Qt.callLater(preview.apply)
  }
}
