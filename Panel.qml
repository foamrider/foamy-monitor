pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "kit"

// The bar widget (one per monitor on 4.5). Display state, the trial helper,
// brightness and FluxCast live once per shell in MonitorService; this file
// owns the bar button (click, wheel brightness with the Omarchy OSD), the
// popup and the IPC target (leader only). MonitorView draws the popup body.
Panel {
  id: root
  moduleName: "foamy.monitor"
  ipcTarget: "foamy.monitor"
  manageIpc: false
  readonly property alias popup: popup
  readonly property alias member: member

  FoamySettingsState { id: settingsState; panel: root }
  readonly property alias editingSettings: settingsState.editing
  property real wheelAccumulator: 0
  readonly property string screenName: popup.screen ? String(popup.screen.name) : ""
  readonly property string language: FoamyI18n.language
  // nf-md-monitor_multiple / nf-md-monitor, escaped so tools cannot drop them.
  readonly property string barGlyph: (MonitorService.activelyCasting || Quickshell.screens.length > 1) ? "\u{f037a}" : "\u{f0379}"

  FoamyMember { id: member; scope: "monitor"; demanding: root.opened }

  // A display change in progress (applying, the 15 s trial, saving,
  // reverting) owns the popup: Settings would cover Keep/Revert and the
  // countdown, so it opens the main view instead and closes if a trial starts.
  function openSettings() {
    if (MonitorService.busy) { open(); return }
    settingsState.show()
  }
  function closeSettings() { settingsState.hide() }

  onOpenedChanged: {
    if (opened) {
      MonitorService.displayChangesSaved = false
      MonitorService.refresh()
    } else {
      // Settings resets on close (FoamySettingsState); the service stops a
      // wireless search once no popup is open and keeps what it found
      // (MonitorService.onDemandedChanged).
      reopenTimer.restart()
    }
  }

  // A trial must be kept or reverted where the user can see it. A geometry
  // change can rebuild a bar, and closing the popup must not hide the
  // countdown: only the focused screen's bar reopens.
  function reopenForTrial() {
    if (!MonitorService.testing || root.opened) return
    if (member.members <= 1 || root.screenName === MonitorService.focusedMonitor) root.open()
    // No bar on the focused output (or it is unknown): the leader shows it.
    else if (member.isLeader && !root.barOnFocused()) root.open()
  }
  function barOnFocused() {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (String(screens[i].name) === MonitorService.focusedMonitor) return true
    return false
  }
  Connections {
    target: MonitorService
    function onTestingChanged() { root.reopenForTrial() }
    function onBusyChanged() { if (MonitorService.busy) root.closeSettings() }
    function onBrightnessStepped(requester, monitor, percent) {
      if (requester === root && percent > 0) root.showBrightnessOsd(percent)
    }
  }
  Component.onCompleted: reopenTimer.restart()
  // Owned by this bar (Qt.callLater would outlive it on unplug).
  Timer { id: reopenTimer; interval: 0; onTriggered: root.reopenForTrial() }

  // ---- Brightness from the bar ---------------------------------------------
  // The wheel adjusts the display this bar is on; IPC adjusts the focused one.
  function wheelTarget() { return root.screenName || MonitorService.focusedMonitor }
  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell || typeof bar.shell.summon !== "function") return
    // omarchy.osd is the summon target a clone of omarchy.monitor may use (4.0 and 4.5).
    bar.shell.summon("omarchy.osd", JSON.stringify({ icon: "brightness", value: percent }))
  }
  function brightnessIpc(value) {
    var target = MonitorService.focusedMonitor
    var text = String(value).trim()
    var relative = /^[+-]/.test(text)
    var number = Number(text.replace(/%$/, ""))
    if (!target) return "error: no focused display"
    if (text === "" || !isFinite(number)) return "error: expected a percentage such as 40, +5 or -5"
    var result = MonitorService.changeBrightness(target, relative ? { delta: number } : { value: number }, root)
    if (result < 0) return "error: brightness is unavailable on " + target
    if (result === 0) return "reading " + target
    return target + " " + result + "%"
  }

  function statusObject() {
    var view = popup.bodyItem
    var brightness = MonitorService.brightnessFor(MonitorService.focusedMonitor)
    return {
      open: root.opened, leader: member.isLeader, members: member.members,
      brightness: brightness && brightness.available ? brightness.percent : null,
      brightnessAvailable: brightness ? brightness.available : null,
      focusedMonitor: MonitorService.focusedMonitor,
      selectedMonitor: view ? view.selectedMonitor : "",
      scale: view && view.selectedLive ? String(view.selectedLive.scale) : "",
      displays: MonitorService.liveMonitors,
      transaction: MonitorService.transaction,
      tab: view ? view.activeTab : "Display",
      editingSettings: root.editingSettings,
      language: root.language,
      statusRuns: MonitorService.statusRuns,
      wirelessDisplay: {
        phase: MonitorService.castPhase, target: MonitorService.castTargetName, monitor: MonitorService.castMonitor,
        scanState: MonitorService.wirelessScanState, peers: MonitorService.wirelessPeers,
        error: MonitorService.wirelessError, missingPackages: MonitorService.missingPackages
      }
    }
  }
  function scanWireless() {
    open()
    var view = popup.ensureBody()
    if (view) view.setTab("Wireless")
    MonitorService.checkWireless()
  }

  FoamyIpc {
    target: "foamy.monitor"
    enabled: member.isLeader
    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return JSON.stringify(root.statusObject()) }
    function status(): string { return JSON.stringify(root.statusObject()) }
    function settings(): void { root.openSettings() }
    function scanWireless(): void { root.scanWireless() }
    function stopWireless(): void { MonitorService.stopCast() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
  }

  // The identify cards: one set per shell, created only while shown.
  Loader {
    active: member.isLeader && MonitorService.identifyVisible
    source: "IdentifyOverlay.qml"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barGlyph
    tooltipText: FoamyI18n.t("Displays")
    onPressed: root.toggle()
    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (!wheel.steps) return
      var percent = MonitorService.changeBrightness(root.wheelTarget(), { delta: wheel.steps * 5 }, root)
      if (percent > 0) root.showBrightnessOsd(percent)
    }
  }

  FoamyPopup {
    id: popup
    objectName: "monitorPopup"
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    wide: true
    body: Component {
      MonitorView { host: root }
    }
  }
}
