pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Ui as Ui
import "Preferences.js" as Preferences
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "foamy.monitor"
  ipcTarget: "foamy.monitor"
  manageIpc: false
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: Color.popups.text
  readonly property color secondary: Qt.tint(Color.popups.background, Qt.alpha(foreground, 0.7))
  readonly property color divider: Qt.alpha(foreground, 0.18)
  readonly property string panelFontFamily: "sans-serif"
  readonly property string language: Preferences.language(Preferences.value(settings, "language"), Qt.locale().name)
  property bool editingSettings: false
  property string settingsError: ""
  property var pendingPreferences: ({})
  function tr(text) {
    return Preferences.text(text, language)
  }
  function openSettings() {
    editingSettings = true
    open()
    panelScroll.contentY = 0
    Qt.callLater(function () {
      settingsPane.focusBack()
    })
  }
  function closeSettings() {
    editingSettings = false
    panelScroll.contentY = 0
    Qt.callLater(function () {
      settingsButton.forceActiveFocus()
    })
  }
  function savePreference(key, value) {
    if (!Preferences.valid(key, value)) {
      settingsError = tr("Invalid setting.")
      return
    }
    settingsError = ""
    pendingPreferences[key] = value
    flushPreferences()
  }
  function flushPreferences() {
    if (preferencesSave.running)
      return
    var keys = Object.keys(pendingPreferences)
    if (!keys.length)
      return
    var key = keys[0], value = pendingPreferences[key]
    delete pendingPreferences[key]
    // Use the shell's writer so other widgets and pending display drafts stay intact.
    preferencesSave.command = ["omarchy-shell", "shell", "setBarWidget", root.moduleName, key, " " + JSON.stringify(value), "{}"]
    preferencesSave.running = true
  }
  Process {
    id: preferencesSave
    stdout: StdioCollector {
      id: preferencesOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: preferencesError
      waitForEnd: true
    }
    onExited: function (code) {
      if (code !== 0 || preferencesOutput.text.trim() !== "ok") {
        root.settingsError = root.tr("Could not save settings.")
        console.warn("foamy.monitor: shell settings write failed (" + code + ")")
      }
      Qt.callLater(root.flushPreferences)
    }
  }
  readonly property string bridge: decodeURIComponent(String(Qt.resolvedUrl("display_transaction.py")).replace(/^file:\/\//, ""))
  readonly property string fluxCastBridge: decodeURIComponent(String(Qt.resolvedUrl("fluxcast_bridge.py")).replace(/^file:\/\//, ""))
  property var transaction: ({
      phase: "idle",
      base: [],
      draft: []
    })
  property var liveMonitors: []
  property var commands: []
  property string selectedMonitor: ""
  property string activeTab: "Display"
  property string localError: ""
  property bool displayChangesSaved: false
  onChangeCountChanged: if (changeCount > 0) displayChangesSaved = false
  readonly property string actionError: localError || transaction.error || ""
  readonly property color changedColor: Color.popups.background.r + Color.popups.background.g + Color.popups.background.b < 1.5 ? "#f9e2af" : "#8b6400"
  property string deferredResult: ""
  property bool arrangementDragActive: false
  property bool identifyVisible: false
  property int wirelessIndex: 0
  property int openDropdowns: 0
  property real now: Date.now()
  property real wheelAccumulator: 0
  readonly property bool testing: transaction.phase === "testing"
  readonly property bool busy: ["applying", "testing", "saving", "reverting"].indexOf(transaction.phase) >= 0
  readonly property int secondsLeft: Math.min(15, Math.max(0, Math.ceil(((transaction.deadline || 0) * 1000 - now) / 1000)))
  readonly property var selected: transaction.draft.find(function (m) {
    return m.id === root.selectedMonitor
  }) || null
  readonly property var selectedLive: liveMonitors.find(function (m) {
    return m.id === root.selectedMonitor
  }) || null
  readonly property var enabledMonitorInfos: transaction.draft.filter(function (m) {
    return m.connected && !m.disabled && !m.mirrorOf
  })
  readonly property int activeCount: transaction.draft.filter(function (m) {
    return m.connected && !m.disabled
  }).length
  readonly property int changeCount: transaction.draft.reduce(function (sum, m) {
    return sum + root.changesFor(m).length
  }, 0) + (gtkScale.base !== gtkScale.value ? 1 : 0)
  readonly property bool disconnectedDraft: transaction.draft.some(function (m) {
    return !m.connected
  })
  readonly property string focusedMonitor: {
    var m = liveMonitors.find(function (m) {
      return m.focused
    })
    return m ? m.name : ""
  }
  readonly property string monitorScale: selectedLive ? String(selectedLive.scale) : ""
  property int cursorSize: 24
  property var gtkScale: ({
      base: null,
      value: null,
      error: ""
    })
  readonly property var gtkScaleOptions: [1, 2, 3, 4].concat(gtkScale.value > 4 ? [gtkScale.value] : []).map(function (v) {
    return {
      value: String(v),
      label: (v * 100) + "%"
    }
  })
  readonly property var cursorSizeOptions: ["24", "30", "36", "48", "72", "96"]
  readonly property var textSizeOptions: ["9", "10", "11", "12", "14", "16", "20"]
  readonly property var rotationOptions: [
    {
      value: "0",
      label: "Landscape · 0°"
    },
    {
      value: "1",
      label: "Portrait · 90°"
    },
    {
      value: "2",
      label: "Landscape · 180°"
    },
    {
      value: "3",
      label: "Portrait · 270°"
    },
    {
      value: "4",
      label: "Flipped · 0°"
    },
    {
      value: "5",
      label: "Flipped · 90°"
    },
    {
      value: "6",
      label: "Flipped · 180°"
    },
    {
      value: "7",
      label: "Flipped · 270°"
    }
  ]
  readonly property var rateOptions: selected ? Model.refreshRatesFor(selected.availableModes, selected.width, selected.height).map(function (v) {
    return {
      value: String(v),
      label: Model.formatHz(v)
    }
  }) : []
  readonly property var scaleOptions: selected ? Model.scaleOptions(selected) : []
  readonly property string scaleValue: {
    if (!selected)
      return ""
    var option = scaleOptions.find(function (v) {
      return Math.abs(Number(v.value) - root.selected.scale) < 0.00001
    })
    return option ? option.value : String(selected.scale)
  }

  function friendlyDisplayName(monitor) {
    return root.tr(Model.friendlyMonitorLabel(monitor))
  }
  function monitorFootprint(monitor) {
    return Model.footprint(monitor)
  }
  function changesFor(monitor) {
    return Model.changedFields(transaction.base.find(function (m) {
      return m.id === monitor.id
    }), monitor)
  }
  function marked(field) {
    return selected && changesFor(selected).indexOf(field) >= 0
  }
  function selectMonitor(id) {
    selectedMonitor = id
    refreshBrightness()
  }
  function enqueue(action, payload) {
    if (action === "status" && (commandProc.running || commands.length || arrangementDragActive))
      return
    commands = commands.concat([
      {
        action: action,
        payload: payload || {}
      }
    ])
    runNext()
  }
  function runNext() {
    if (commandProc.running || !commands.length)
      return
    var next = commands[0]
    commands = commands.slice(1)
    commandProc.action = next.action
    commandProc.payload = next.payload
    commandProc.command = ["python3", bridge, next.action]
    commandProc.running = true
  }
  function acceptResult(text) {
    if (arrangementDragActive) {
      deferredResult = text
      return
    }
    try {
      var result = JSON.parse(text)
      if (!result.ok) {
        localError = result.error
        return
      }
      // A clean draft alone is not proof of a save: wait for Keep to finish successfully.
      if (busy && result.state.phase === "idle")
        displayChangesSaved = result.state.decision === "keep" && !result.state.error && result.state.token === transaction.token
      if (JSON.stringify(transaction) !== JSON.stringify(result.state))
        transaction = result.state
      liveMonitors = result.live
      gtkScale = result.gtkScale || {
        base: null,
        value: null,
        error: "Could not read GTK scale"
      }
      if (!selectedLive || selectedLive.disabled)
        brightnessAvailable = false
      if (commandProc.action !== "status")
        localError = ""
      if (!selected) {
        var focused = transaction.draft.find(function (m) {
          return m.focused
        }) || transaction.draft[0]
        if (focused)
          selectMonitor(focused.id)
      }
      // A geometry change can rebuild a bar. Only the focused screen reopens.
      if (testing && !opened && panel.screen && panel.screen.name === focusedMonitor)
        root.open()
    } catch (error) {
      localError = "Could not read display settings: " + error
    }
  }
  function edit(changes, monitor) {
    monitor = monitor || selected
    if (!monitor || busy)
      return
    enqueue("patch", {
      id: monitor.id,
      changes: changes
    })
  }
  function setResolution(value) {
    var size = value.split("x").map(Number)
    var rates = Model.refreshRatesFor(selected.availableModes, size[0], size[1])
    var scale = Model.validScale(selected.scale, size[0], size[1]) ? selected.scale : 1
    edit({
      width: size[0],
      height: size[1],
      refreshRate: Model.nearestRate(rates, selected.refreshRate),
      scale: scale
    })
  }
  function toggleDisplay() {
    if (!selected)
      return
    var values = {
      disabled: !selected.disabled,
      mirrorOf: ""
    }
    if (selected.disabled) {
      var right = enabledMonitorInfos.reduce(function (x, m) {
        return Math.max(x, m.x + Model.footprint(m).w)
      }, 0)
      values.x = right
      values.y = 0
    }
    edit(values)
  }
  function setMirror(value) {
    if (!selected)
      return
    var values = {
      mirrorOf: value
    }
    if (!value) {
      values.x = enabledMonitorInfos.filter(function (m) {
        return m.id !== root.selectedMonitor
      }).reduce(function (x, m) {
        return Math.max(x, m.x + Model.footprint(m).w)
      }, 0)
      values.y = 0
    }
    edit(values)
  }
  function moveMonitor(name, x, y) {
    var monitor = transaction.draft.find(function (m) {
      return m.name === name
    })
    if (monitor)
      edit({
        x: Math.round(x),
        y: Math.round(y)
      }, monitor)
  }
  function save() {
    if (changeCount && !busy && !disconnectedDraft)
      enqueue("apply")
  }
  function decide(action) {
    enqueue(action, {
      token: transaction.token
    })
  }
  function showIdentify() {
    identifyVisible = true
    identifyTimer.restart()
  }
  function refresh() {
    enqueue("status")
    if (opened && !cursorInfoProc.running)
      cursorInfoProc.running = true
    refreshBrightness()
  }

  // Brightness reads and writes keep their target across monitor selection.
  property bool brightnessAvailable: false
  property int brightnessPercent: 0
  property var queuedBrightness: null
  property var brightnessPreview: null
  function refreshBrightness() {
    if (!selectedLive || selectedLive.disabled || brightnessRead.running || brightnessWrite.running || brightnessPreview)
      return
    brightnessRead.monitor = selectedLive.name
    brightnessRead.command = ["omarchy-brightness-display", "--monitor", selectedLive.name]
    brightnessRead.running = true
  }
  function setBrightness(value) {
    if (!selectedLive || !brightnessAvailable)
      return
    brightnessPercent = Model.clampBrightness(value)
    brightnessPreview = {
      monitor: selectedLive.name,
      value: brightnessPercent
    }
    brightnessDebounce.restart()
  }
  function flushBrightness() {
    if (brightnessPreview) {
      queuedBrightness = brightnessPreview
      brightnessPreview = null
    }
    if (!queuedBrightness || brightnessWrite.running)
      return
    var next = queuedBrightness
    queuedBrightness = null
    brightnessWrite.command = ["omarchy-brightness-display", "--no-osd", "--monitor", next.monitor, next.value + "%"]
    brightnessWrite.running = true
  }
  function brightnessIpc(percent) {
    setBrightness(Number(percent))
    return "got " + brightnessPercent
  }
  function setCursorSize(value) {
    if (advancedProc.running)
      return
    advancedProc.command = ["bash", "-c", 'theme=$(gsettings get org.gnome.desktop.interface cursor-theme); theme=${theme//\'/}; gsettings set org.gnome.desktop.interface cursor-size "$1" && hyprctl setcursor "$theme" "$1"', "cursor-size", String(value)]
    advancedProc.running = true
  }
  function setTextSize(value) {
    if (advancedProc.running)
      return
    advancedProc.command = ["omarchy-display-text-size", String(value)]
    advancedProc.running = true
  }

  property var wirelessPeers: []
  property var missingPackages: []
  property string wirelessScanState: "idle"
  property bool wirelessCacheValid: false
  readonly property bool scanning: scanProc.running || dependenciesProc.running
  property int scanDots: 1
  property string wirelessError: ""
  property string castPhase: "idle"
  property string castDetail: ""
  property string castTargetName: ""
  property string castTargetAddress: ""
  property string castMonitor: ""
  property bool castExpectedStop: false
  property bool wirelessScanExpectedStop: false
  readonly property bool castRunning: castProc.running
  readonly property bool activelyCasting: castRunning && castPhase === "casting"
  function wirelessPeerLabel(peer) {
    return peer.name || tr("Wireless display")
  }
  function wirelessPhaseLabel() {
    if (castPhase === "casting")
      return tr("Casting to %1").replace("%1", castTargetName)
    if (castPhase === "stopping")
      return tr("Stopping…")
    if (castPhase === "error")
      return castDetail
    return tr("Connecting to %1…").replace("%1", castTargetName)
  }
  function checkWireless(force) {
    if (dependenciesProc.running || scanProc.running || castRunning || (wirelessCacheValid && !force))
      return
    dependenciesProc.running = true
  }
  function startWirelessScan() {
    if (scanProc.running || castRunning || missingPackages.length)
      return
    wirelessScanExpectedStop = false
    wirelessCacheValid = false
    wirelessPeers = []
    wirelessError = ""
    wirelessScanState = "scanning"
    scanProc.command = ["python3", fluxCastBridge, "scan", "--timeout", "8"]
    scanProc.running = true
  }
  function cancelWirelessScan() {
    if (!scanProc.running || wirelessScanExpectedStop)
      return
    wirelessScanExpectedStop = true
    scanProc.signal(15)
  }
  function connectWirelessPeer(peer) {
    if (!peer || scanProc.running || castRunning || missingPackages.length)
      return
    var monitor = selectedLive && !selectedLive.disabled ? selectedLive.name : focusedMonitor
    if (!monitor) {
      wirelessError = "No enabled display"
      return
    }
    castTargetName = wirelessPeerLabel(peer)
    castTargetAddress = peer.address
    castMonitor = monitor
    castExpectedStop = false
    castPhase = "starting"
    castDetail = ""
    wirelessError = ""
    castProc.command = ["python3", fluxCastBridge, "cast", "--peer", peer.address, "--monitor", monitor, "--output-res", "1920x1080", "--fps", "30", "--bitrate", "4M", "--timeout", "8"]
    castProc.running = true
  }
  function stopCast() {
    if (!castRunning || castExpectedStop)
      return
    castExpectedStop = true
    castPhase = "stopping"
    castProc.signal(15)
    castStopWatchdog.restart()
  }
  function applyCastEvent(line) {
    var event = Model.parseFluxCastEvent(line)
    if (!event)
      return
    if (event.type === "phase") {
      castPhase = String(event.phase)
      castDetail = String(event.detail || "")
      if (castPhase === "error")
        wirelessError = castDetail
    }
  }
  function stateIpc() {
    return JSON.stringify({
      brightness: brightnessAvailable ? brightnessPercent : null,
      brightnessAvailable: brightnessAvailable,
      focusedMonitor: focusedMonitor,
      selectedMonitor: selectedMonitor,
      scale: monitorScale,
      displays: liveMonitors,
      transaction: transaction,
      tab: activeTab,
      editingSettings: editingSettings,
      language: language,
      settingsError: settingsError,
      wirelessDisplay: {
        phase: castPhase,
        target: castTargetName,
        monitor: castMonitor,
        scanState: wirelessScanState,
        peers: wirelessPeers,
        error: wirelessError,
        missingPackages: missingPackages
      }
    })
  }
  IpcHandler {
    target: "foamy.monitor"
    function brightness(percent: string): string {
      return root.brightnessIpc(percent)
    }
    function state(): string {
      return root.stateIpc()
    }
    function settings() {
      root.openSettings()
    }
    function scanWireless() {
      root.activeTab = "Wireless"
      root.checkWireless(true)
    }
    function stopWireless() {
      root.stopCast()
    }
    function open() {
      root.open()
    }
    function close() {
      root.close()
    }
    function toggle() {
      root.toggle()
    }
    function show() {
      root.open()
    }
    function hide() {
      root.close()
    }
  }
  Component.onCompleted: refresh()
  onOpenedChanged: {
    if (opened) {
      displayChangesSaved = false
      refresh()
      if (activeTab === "Wireless")
        checkWireless()
    } else {
      editingSettings = false
      // Reuse completed searches across tabs until this popup is closed.
      wirelessCacheValid = false
      cancelWirelessScan()
    }
  }
  onActiveTabChanged: if (activeTab === "Wireless" && opened)
    checkWireless()
  onSelectedMonitorChanged: {
    brightnessAvailable = false
    Qt.callLater(refreshBrightness)
  }
  onTestingChanged: if (testing) {
    now = Date.now()
    Qt.callLater(function () {
      revertButton.forceActiveFocus()
    })
  }
  onArrangementDragActiveChanged: if (!arrangementDragActive && deferredResult) {
    var result = deferredResult
    deferredResult = ""
    Qt.callLater(function () {
      root.acceptResult(result)
    })
  }

  Process {
    id: commandProc
    property string action: ""
    property var payload: ({})
    stdinEnabled: true
    onStarted: write(JSON.stringify(payload) + "\n")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.acceptResult(text)
    }
    stderr: StdioCollector {
      id: commandError
      waitForEnd: true
    }
    onExited: function (code) {
      if (code && commandError.text)
        root.localError = String(commandError.text).trim()
      Qt.callLater(root.runNext)
    }
  }
  Timer {
    interval: root.busy ? 250 : 2000
    repeat: true
    running: true
    onTriggered: root.enqueue("status")
  }
  Timer {
    interval: 100
    repeat: true
    running: root.testing
    onTriggered: root.now = Date.now()
  }
  Timer {
    interval: 5000
    repeat: true
    running: root.opened
    onTriggered: root.refresh()
  }
  Timer {
    id: identifyTimer
    interval: 2500
    onTriggered: root.identifyVisible = false
  }
  Timer {
    id: brightnessDebounce
    interval: 150
    onTriggered: root.flushBrightness()
  }
  Process {
    id: brightnessRead
    property string monitor: ""
    stdout: StdioCollector {
      id: brightnessOutput
      waitForEnd: true
    }
    onExited: function (code) {
      if (!root.selectedLive || monitor !== root.selectedLive.name) {
        Qt.callLater(root.refreshBrightness)
        return
      }
      if (root.brightnessPreview || brightnessWrite.running)
        return
      var value = Number(String(brightnessOutput.text).trim())
      root.brightnessAvailable = code === 0 && String(brightnessOutput.text).trim() !== "" && isFinite(value)
      if (root.brightnessAvailable)
        root.brightnessPercent = Math.round(value)
    }
  }
  Process {
    id: brightnessWrite
    stderr: StdioCollector {
      id: brightnessError
      waitForEnd: true
    }
    onExited: function (code) {
      if (code)
        root.localError = String(brightnessError.text).trim() || "Could not set brightness"
      Qt.callLater(root.flushBrightness)
    }
  }
  Process {
    id: cursorInfoProc
    command: ["gsettings", "get", "org.gnome.desktop.interface", "cursor-size"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var n = Number(String(text).trim())
        if (isFinite(n) && n > 0)
          root.cursorSize = n
      }
    }
  }
  Process {
    id: advancedProc
    stderr: StdioCollector {
      id: advancedError
      waitForEnd: true
    }
    onExited: function (code) {
      if (code)
        root.localError = String(advancedError.text).trim() || "Could not update advanced settings"
      root.refresh()
    }
  }
  Process {
    id: dependenciesProc
    command: ["python3", root.fluxCastBridge, "check"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.parseFluxCastScan(text)
        root.missingPackages = result.missingPackages || []
        root.wirelessError = result.error
        if (root.missingPackages.length)
          root.wirelessScanState = "missing"
        else if (!result.error && root.opened && root.activeTab === "Wireless")
          root.startWirelessScan()
      }
    }
  }
  Timer {
    interval: 10000
    repeat: true
    running: root.opened && root.activeTab === "Wireless" && root.missingPackages.length > 0
    onTriggered: root.checkWireless(true)
  }
  Timer {
    interval: 400
    repeat: true
    running: root.opened && root.activeTab === "Wireless" && root.scanning
    onRunningChanged: if (running)
      root.scanDots = 1
    onTriggered: root.scanDots = root.scanDots % 3 + 1
  }
  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.wirelessScanExpectedStop)
          return
        var result = Model.parseFluxCastScan(text)
        root.wirelessPeers = result.peers
        root.wirelessError = result.error
        root.missingPackages = result.missingPackages || []
        root.wirelessScanState = result.error ? "error" : result.peers.length ? "results" : "empty"
        root.wirelessCacheValid = root.opened
        root.wirelessIndex = 0
      }
    }
    onExited: function (code) {
      if (root.wirelessScanExpectedStop) {
        root.wirelessScanExpectedStop = false
        root.wirelessScanState = "idle"
        // A quick reopen may have happened before the old process stopped.
        if (root.opened && root.activeTab === "Wireless")
          Qt.callLater(root.checkWireless)
        return
      }
      if (root.wirelessScanState === "scanning") {
        root.wirelessScanState = "error"
        root.wirelessCacheValid = root.opened
        root.wirelessError = "Wireless display scan failed"
      }
    }
  }
  Process {
    id: castProc
    stdout: SplitParser {
      onRead: function (line) {
        root.applyCastEvent(line)
      }
    }
    onExited: function (code) {
      castStopWatchdog.stop()
      if (root.castExpectedStop) {
        root.castPhase = "idle"
        root.castDetail = ""
      } else if (root.castPhase !== "idle" && root.castPhase !== "error") {
        root.castPhase = "error"
        root.wirelessError = "Cast ended (" + code + ")"
      }
      root.castExpectedStop = false
    }
  }
  Timer {
    id: castStopWatchdog
    interval: 12000
    onTriggered: if (castProc.running)
      castProc.signal(15)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.activelyCasting ? "󰍺" : "󰍹"
    onPressed: root.toggle()
    onWheelMoved: function (delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps && root.brightnessAvailable)
        root.setBrightness(root.brightnessPercent + wheel.steps * 5)
    }
  }
  MonitorPopup {
    id: panel
    objectName: "monitorPopup"
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    padding: 0
    borderSpec: Border.flat(Qt.alpha(Color.popups.text, 0.15), 1)
    // Keep the settings action neutral on open; Tab still gives it a visible focus ring.
    focusTarget: root.testing ? revertButton : root.editingSettings ? settingsPane.backTarget : keyboard
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight((root.editingSettings ? settingsPane.implicitHeight : panelColumn.implicitHeight) + footer.height, Style.space(900))

    Rectangle {
      id: keyboard
      objectName: "monitorPanelContent"
      color: Color.popups.background
      radius: Style.space(13)
      anchors.fill: parent
      focus: true
      Keys.onPressed: function (event) {
        if (root.openDropdowns > 0)
          return
        if (event.key === Qt.Key_Escape) {
          if (root.testing)
            root.decide("revert")
          else if (root.editingSettings)
            root.closeSettings()
          else
            root.close()
          event.accepted = true
        } else if (!root.editingSettings && (event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_S) {
          root.save()
          event.accepted = true
        } else if (!root.editingSettings && (event.text === "w" || event.text === "W")) {
          root.activeTab = "Wireless"
          event.accepted = true
        } else if (!root.editingSettings && root.activeTab === "Wireless" && (event.key === Qt.Key_Down || event.text === "j" || event.key === Qt.Key_Up || event.text === "k")) {
          root.wirelessIndex = Math.max(0, Math.min(root.wirelessPeers.length - 1, root.wirelessIndex + ((event.key === Qt.Key_Down || event.text === "j") ? 1 : -1)))
          event.accepted = true
        } else if (!root.editingSettings && root.activeTab === "Wireless" && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
          if (root.castRunning)
            root.stopCast()
          else
            root.connectWirelessPeer(root.wirelessPeers[root.wirelessIndex])
          event.accepted = true
        }
      }
      Flickable {
        id: panelScroll
        anchors {
          left: parent.left
          right: parent.right
          top: parent.top
          bottom: footer.top
        }
        clip: true
        contentWidth: width
        contentHeight: root.editingSettings ? settingsPane.implicitHeight : panelColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        onContentHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
        onHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
        QQC.ScrollBar.vertical: QQC.ScrollBar {
          policy: QQC.ScrollBar.AsNeeded
        }
        // Reveal focused controls when a small output requires scrolling.
        Connections {
          target: panelScroll.Window.window
          function onActiveFocusItemChanged() {
            var item = target.activeFocusItem
            if (!item)
              return
            var ancestor = item
            while (ancestor && ancestor !== panelScroll.contentItem)
              ancestor = ancestor.parent
            if (!ancestor)
              return
            var point = item.mapToItem(panelScroll.contentItem, 0, 0)
            if (point.y < panelScroll.contentY)
              panelScroll.contentY = Math.max(0, point.y - Style.space(8))
            else if (point.y + item.height > panelScroll.contentY + panelScroll.height)
              panelScroll.contentY = Math.max(0, Math.min(panelScroll.contentHeight - panelScroll.height, point.y + item.height - panelScroll.height + Style.space(8)))
          }
        }
        SettingsPane {
          id: settingsPane
          visible: root.editingSettings
          width: panelScroll.width
          settings: root.settings
          language: root.language
          saving: preferencesSave.running
          error: root.settingsError
          pendingDisplayChanges: root.changeCount > 0
          onBack: root.closeSettings()
          onSave: function (key, value) {
            root.savePreference(key, value)
          }
        }
        Column {
          id: panelColumn
          visible: !root.editingSettings
          width: panelScroll.width
          Rectangle {
            width: parent.width
            height: headerContent.implicitHeight + Style.space(40)
            topLeftRadius: Style.space(13)
            topRightRadius: Style.space(13)
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop {
                position: 0
                color: Qt.tint(Color.popups.background, Qt.alpha(Color.accent, 0.07))
              }
              GradientStop {
                position: 1
                color: Qt.tint(Color.popups.background, Qt.alpha(Color.popups.text, 0.12))
              }
            }
            Column {
              id: headerContent
              anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                margins: Style.space(20)
              }
              spacing: Style.space(16)
              RowLayout {
                width: parent.width
                MonitorIcon {
                  name: "monitor"
                  Layout.preferredWidth: Style.space(16)
                  Layout.preferredHeight: Style.space(16)
                  color: root.secondary
                }
                Label {
                  text: root.tr("Displays")
                  font.pixelSize: Style.space(13)
                  Layout.fillWidth: true
                }
                MonitorAction {
                  id: settingsButton
                  implicitWidth: Style.space(32)
                  implicitHeight: Style.space(32)
                  radius: Style.space(7)
                  iconSize: Style.space(16)
                  tooltipText: root.tr("Plugin settings")
                  foreground: root.secondary
                  onClicked: root.openSettings()
                }
              }
              Column {
                width: parent.width
                spacing: Style.space(4)
                Label {
                  width: parent.width
                  text: root.tr("Your workspace")
                  font.pixelSize: Style.space(24)
                  wrapMode: Text.WordWrap
                }
              }
            }
          }
          Item {
            width: parent.width
            height: Style.space(42)
            Rectangle {
              anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
              }
              height: 1
              color: root.divider
            }
            Row {
              anchors {
                left: parent.left
                leftMargin: Style.space(20)
                top: parent.top
                topMargin: Style.space(8)
                bottom: parent.bottom
              }
              spacing: Style.space(22)
              Repeater {
                model: ["Display", "Advanced", "Wireless"]
                MonitorAction {
                  required property string modelData
                  height: parent.height
                  iconName: ""
                  label: root.tr(modelData)
                  foreground: root.activeTab === modelData ? root.foreground : root.secondary
                  onClicked: root.activeTab = modelData
                  Rectangle {
                    anchors {
                      left: parent.left
                      right: parent.right
                      bottom: parent.bottom
                    }
                    height: Style.space(2)
                    color: root.foreground
                    visible: root.activeTab === parent.modelData
                  }
                }
              }
            }
          }
          Column {
            width: parent.width
            padding: Style.space(20)
            spacing: Style.space(16)
            Label {
              width: parent.width - Style.space(40)
              visible: root.actionError !== ""
              text: root.tr(root.actionError)
              color: Color.urgent
              wrapMode: Text.WordWrap
              Accessible.role: Accessible.AlertMessage
            }
            Label {
              width: parent.width - Style.space(40)
              visible: !root.transaction.draft.length && !root.actionError
              text: root.tr("Reading displays…")
              muted: true
            }
            Column {
              width: parent.width - Style.space(40)
              visible: root.activeTab === "Display" && root.transaction.draft.length > 0
              spacing: Style.space(16)
              enabled: !root.busy
              Rectangle {
                width: parent.width
                height: layoutContent.implicitHeight + Style.space(28)
                radius: Style.space(8)
                color: Qt.tint(Color.popups.background, Qt.alpha(root.foreground, 0.045))
                Column {
                  id: layoutContent
                  anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    margins: Style.space(14)
                  }
                  spacing: Style.space(10)
                  ArrangementDiagram {
                    width: parent.width
                    visible: root.enabledMonitorInfos.length > 0
                  }
                  RowLayout {
                    width: parent.width
                    Label {
                      text: root.tr("Drag to arrange")
                      muted: true
                      small: true
                      Layout.fillWidth: true
                    }
                    MonitorAction {
                      iconName: "scan"
                      label: root.tr("Identify")
                      tooltipText: root.tr("Identify displays")
                      foreground: root.secondary
                      onClicked: root.showIdentify()
                    }
                  }
                }
              }
              // Disabled or disconnected drafts must remain selectable outside the diagram.
              Repeater {
                model: root.transaction.draft.filter(function (m) {
                  return m.disabled || !m.connected || !!m.mirrorOf
                })
                MonitorAction {
                  required property var modelData
                  width: parent.width
                  iconName: "monitor"
                  label: root.friendlyDisplayName(modelData) + " · " + root.tr(!modelData.connected ? "Disconnected" : modelData.mirrorOf ? "Mirrored" : "Off")
                  foreground: root.selectedMonitor === modelData.id ? root.foreground : root.secondary
                  onClicked: root.selectMonitor(modelData.id)
                }
              }
              Field {
                width: parent.width
                label: "Display mode"
                dirty: root.marked("mirror")
                currentValue: root.selected ? root.selected.mirrorOf : ""
                options: [
                  {
                    value: "",
                    label: root.tr("Extend")
                  }
                ].concat(root.transaction.draft.filter(function (m) {
                  return m.connected && !m.disabled && !m.mirrorOf && m.id !== root.selectedMonitor
                }).map(function (m) {
                  return {
                    value: m.name,
                    label: root.tr("Mirror %1").replace("%1", root.friendlyDisplayName(m))
                  }
                }))
                enabled: !!root.selected && root.selected.connected && !root.selected.disabled
                onChanged: function (value) {
                  root.setMirror(value)
                }
              }
              RowLayout {
                width: parent.width
                Label {
                  text: root.selected ? root.friendlyDisplayName(root.selected) : ""
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                }
                Button {
                  text: root.tr(root.selected && root.selected.disabled ? "Turn on" : "Turn off")
                  enabled: !!root.selected && root.selected.connected && (root.selected.disabled || root.activeCount > 1)
                  onClicked: root.toggleDisplay()
                }
              }
              GridLayout {
                width: parent.width
                columns: width < Style.space(340) ? 1 : 2
                columnSpacing: Style.space(16)
                rowSpacing: Style.space(16)
                enabled: !!root.selected && root.selected.connected
                Field {
                  Layout.fillWidth: true
                  label: "Resolution"
                  dirty: root.marked("resolution")
                  options: Model.resolutionOptions(root.selected)
                  currentValue: root.selected ? root.selected.width + "x" + root.selected.height : ""
                  onChanged: function (value) {
                    root.setResolution(value)
                  }
                }
                Field {
                  Layout.fillWidth: true
                  label: "Refresh rate"
                  dirty: root.marked("rate")
                  options: root.rateOptions
                  currentValue: root.selected ? String(root.selected.refreshRate) : ""
                  onChanged: function (value) {
                    root.edit({
                      refreshRate: Number(value)
                    })
                  }
                }
                Field {
                  Layout.fillWidth: true
                  label: "Scale"
                  dirty: root.marked("scale")
                  options: root.scaleOptions
                  currentValue: root.scaleValue
                  onChanged: function (value) {
                    root.edit({
                      scale: Number(value)
                    })
                  }
                }
                Field {
                  Layout.fillWidth: true
                  label: "Orientation"
                  dirty: root.marked("rotation")
                  options: root.rotationOptions.map(function (o) {
                    return {
                      value: o.value,
                      label: root.tr(o.label)
                    }
                  })
                  currentValue: root.selected ? String(root.selected.transform) : "0"
                  onChanged: function (value) {
                    root.edit({
                      transform: Number(value)
                    })
                  }
                }
              }
              Column {
                width: parent.width
                spacing: Style.space(8)
                RowLayout {
                  width: parent.width
                  Label {
                    text: root.tr("Brightness")
                    muted: true
                    small: true
                    Layout.fillWidth: true
                  }
                  Label {
                    text: root.brightnessAvailable ? root.brightnessPercent + "%" : root.tr("Unavailable")
                    muted: true
                    small: true
                  }
                }
                PanelSlider {
                  width: parent.width
                  bar: root.bar
                  minimum: 1
                  maximum: 100
                  step: 1
                  integer: true
                  value: root.brightnessPercent
                  enabled: root.brightnessAvailable
                  opacity: enabled ? 1 : 0.35
                  activeFocusOnTab: enabled
                  Keys.onLeftPressed: root.setBrightness(root.brightnessPercent - 5)
                  Keys.onRightPressed: root.setBrightness(root.brightnessPercent + 5)
                  onMoved: function (value) {
                    root.setBrightness(value)
                  }
                }
              }
            }
            GridLayout {
              width: parent.width - Style.space(40)
              visible: root.activeTab === "Advanced"
              enabled: !root.busy
              columns: width < Style.space(340) ? 1 : 2
              columnSpacing: Style.space(16)
              rowSpacing: Style.space(16)
              Field {
                Layout.fillWidth: true
                label: "Text size"
                options: root.textSizeOptions.map(function (v) {
                  return {
                    value: v,
                    label: v + " px"
                  }
                })
                currentValue: String(Style.font.baseSize)
                enabled: !advancedProc.running
                onChanged: function (value) {
                  root.setTextSize(value)
                }
              }
              Field {
                Layout.fillWidth: true
                label: "Cursor size"
                options: root.cursorSizeOptions.map(function (v) {
                  return {
                    value: v,
                    label: v + " px"
                  }
                })
                currentValue: String(root.cursorSize)
                enabled: !advancedProc.running
                onChanged: function (value) {
                  root.setCursorSize(value)
                }
              }
              Field {
                Layout.fillWidth: true
                label: "GTK scale"
                dirty: root.gtkScale.base !== root.gtkScale.value
                options: root.gtkScaleOptions
                currentValue: root.gtkScale.value === null ? root.tr("Unavailable") : String(root.gtkScale.value)
                enabled: root.gtkScale.value !== null && root.gtkScale.error === ""
                onChanged: function (value) {
                  root.enqueue("gtk-scale", {
                    value: Number(value)
                  })
                }
              }
              Label {
                Layout.fillWidth: true
                Layout.columnSpan: parent.columns
                text: root.tr(root.gtkScale.error || "Text and cursor size apply immediately. GTK scale is included in Save; reopen apps after keeping it.")
                color: root.gtkScale.error ? Color.urgent : root.secondary
                small: true
                wrapMode: Text.WordWrap
              }
            }
            Column {
              width: parent.width - Style.space(40)
              visible: root.activeTab === "Wireless"
              spacing: Style.space(14)
              enabled: !root.busy
              RowLayout {
                width: parent.width
                Label {
                  text: root.tr("Wireless displays")
                  Layout.fillWidth: true
                }
                Button {
                  text: root.tr(root.castRunning ? "Stop" : "Scan")
                  enabled: root.castRunning ? !root.castExpectedStop : !scanProc.running && !dependenciesProc.running
                  onClicked: root.castRunning ? root.stopCast() : root.checkWireless(true)
                }
              }
              Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                topPadding: Style.space(20)
                bottomPadding: Style.space(20)
                visible: root.castRunning || root.wirelessPeers.length === 0 || root.wirelessError !== ""
                text: root.castRunning ? root.wirelessPhaseLabel() : root.wirelessError ? root.tr(root.wirelessError) : root.scanning ? root.tr("Scanning…") : root.wirelessScanState === "idle" ? "" : root.tr("No receivers found")
                muted: true
              }
              Repeater {
                model: !root.castRunning && !scanProc.running ? root.wirelessPeers : []
                Button {
                  required property var modelData
                  required property int index
                  width: parent.width
                  text: root.wirelessPeerLabel(modelData)
                  hasCursor: root.wirelessIndex === index
                  leftAlign: true
                  onClicked: root.connectWirelessPeer(modelData)
                  onHovered: function (hovered) {
                    if (hovered)
                      root.wirelessIndex = index
                  }
                }
              }
            }
          }
        }
      }
      Rectangle {
        id: footer
        bottomLeftRadius: Style.space(13)
        bottomRightRadius: Style.space(13)
        anchors {
          left: parent.left
          right: parent.right
          bottom: parent.bottom
        }
        height: root.editingSettings && !root.busy ? 0 : footerContent.implicitHeight + Style.space(28)
        visible: height > 0
        color: root.busy ? Qt.tint(Color.popups.background, Qt.alpha(root.foreground, 0.05)) : Color.popups.background
        Rectangle {
          width: parent.width
          height: 1
          color: root.divider
        }
        Column {
          id: footerContent
          anchors {
            left: parent.left
            right: parent.right
            verticalCenter: parent.verticalCenter
            margins: Style.space(20)
          }
          spacing: Style.space(10)
          Label {
            visible: root.busy
            width: parent.width
            text: root.tr(root.testing ? "Keep these settings?" : root.transaction.phase === "reverting" ? "Reverting…" : root.transaction.phase === "saving" ? "Saving…" : "Applying…")
            wrapMode: Text.WordWrap
          }
          Flow {
            width: parent.width
            spacing: Style.space(10)
            Label {
              objectName: "monitorSaveStatus"
              width: Math.max(Style.space(100), parent.width - actions.implicitWidth - parent.spacing)
              height: actions.height
              verticalAlignment: Text.AlignVCenter
              text: root.testing ? root.tr("Reverting in %1 s").replace("%1", root.secondsLeft) : root.changeCount ? root.tr(root.changeCount === 1 ? "%1 unsaved change" : "%1 unsaved changes").replace("%1", root.changeCount) : root.displayChangesSaved && !root.actionError ? root.tr("All changes saved") : ""
              color: root.changeCount || root.testing ? root.changedColor : root.secondary
              small: true
              wrapMode: Text.WordWrap
            }
            Row {
              id: actions
              spacing: Style.space(8)
              Button {
                visible: !root.busy && root.changeCount > 0
                text: root.tr("Discard")
                onClicked: root.enqueue("discard")
              }
              Button {
                id: revertButton
                visible: root.testing
                text: root.tr("Revert")
                onClicked: root.decide("revert")
              }
              PrimaryButton {
                visible: !root.busy || root.testing
                text: root.tr(root.testing ? "Keep settings" : "Save")
                enabled: root.testing || root.changeCount > 0 && !root.busy && !root.disconnectedDraft
                onClicked: root.testing ? root.decide("keep") : root.save()
              }
            }
          }
          Rectangle {
            visible: root.testing
            width: parent.width
            height: Style.space(2)
            color: root.divider
            Rectangle {
              height: parent.height
              width: parent.width * root.secondsLeft / 15
              color: root.foreground
            }
          }
        }
      }
    }
  }
  Variants {
    model: Quickshell.screens
    delegate: PanelWindow {
      id: identifyWindow
      required property var modelData
      screen: modelData
      visible: root.identifyVisible
      exclusionMode: ExclusionMode.Ignore
      implicitWidth: Style.space(300)
      implicitHeight: Style.space(120)
      color: "transparent"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      WlrLayershell.namespace: "foamy-monitor-identify"
      mask: Region {}
      Rectangle {
        anchors.fill: parent
        color: Color.popups.background
        border.color: Color.accent
        border.width: Style.normalBorderWidth
        radius: Style.cornerRadius
        Label {
          anchors.centerIn: parent
          text: root.friendlyDisplayName(root.liveMonitors.find(function (m) {
            return m.name === identifyWindow.modelData.name
          }) || {
            name: identifyWindow.modelData.name
          })
          font.pixelSize: Style.font.title
        }
      }
    }
  }
  component Button: Ui.Button {
    focusable: true
    bordered: true
    fontFamily: root.panelFontFamily
    fontSize: Style.space(12)
    foreground: root.foreground
    radius: Style.space(7)
    borderSpec: Border.flat(activeFocus ? root.foreground : root.divider, 1)
    color: hot || activeFocus ? Qt.alpha(root.foreground, 0.1) : Qt.alpha(root.foreground, 0.035)
    opacity: enabled ? 1 : 0.4
  }
  component Label: Text {
    property bool muted: false
    property bool small: false
    textFormat: Text.PlainText
    color: muted ? root.secondary : root.foreground
    font.family: root.panelFontFamily
    font.pixelSize: Style.space(small ? 12 : 14)
  }
  component PrimaryButton: Button {
    foreground: Color.popups.background
    color: hot || activeFocus ? Qt.alpha(root.foreground, 0.85) : root.foreground
    borderSpec: Border.flat(root.foreground, 1)
  }
  component ChangeLabel: Row {
    id: changeLabel
    property string label: ""
    property bool dirty: false
    property bool bold: false
    property real fontSize: Style.font.caption
    property color foreground: root.foreground
    spacing: Style.space(6)
    Label {
      text: changeLabel.label
      color: changeLabel.foreground
      font.pixelSize: changeLabel.fontSize
      font.bold: changeLabel.bold
    }
    Label {
      text: root.tr("· changed")
      visible: changeLabel.dirty
      color: root.changedColor
      font.pixelSize: changeLabel.fontSize
      font.bold: changeLabel.bold
    }
  }
  component Field: Item {
    id: field
    property string label: ""
    property bool dirty: false
    property string currentValue: ""
    property alias options: dropdown.options
    readonly property int rowHeight: dropdown.rowHeight
    readonly property bool popupOpen: dropdown.popupOpen
    signal changed(string value)
    implicitWidth: dropdown.implicitWidth
    implicitHeight: fieldLabel.implicitHeight + Style.spacing.labelGap + rowHeight
    ChangeLabel {
      id: fieldLabel
      label: root.tr(field.label)
      dirty: field.dirty
      bold: false
      foreground: root.secondary
    }
    MonitorDropdown {
      id: dropdown
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      showLabel: false
      value: field.currentValue
      // Rebind the draft value when selection closes, including after a revert.
      Binding {
        target: dropdown
        property: "value"
        value: field.currentValue
        when: !dropdown.popupOpen
      }
      foreground: root.foreground
      fontFamily: root.panelFontFamily
      onChanged: function (value) {
        field.changed(value)
      }
    }
    opacity: enabled ? 1 : 0.4
    onPopupOpenChanged: root.openDropdowns += popupOpen ? 1 : -1
  }
  component ArrangementDiagram: Item {
    id: diagram
    height: Style.space(150)

    readonly property var boxes: {
      var infos = root.enabledMonitorInfos
      var out = []
      for (var i = 0; i < infos.length; i++) {
        var info = infos[i]
        var f = root.monitorFootprint(info)
        out.push({
          name: info.name,
          number: i + 1,
          label: root.friendlyDisplayName(info),
          x: info.x,
          y: info.y,
          w: f.w,
          h: f.h,
          focused: info.id === root.selectedMonitor
        })
      }
      return out
    }

    readonly property real minX: {
      if (boxes.length === 0)
        return 0
      var m = boxes[0].x
      for (var i = 1; i < boxes.length; i++)
        if (boxes[i].x < m)
          m = boxes[i].x
      return m
    }
    readonly property real minY: {
      if (boxes.length === 0)
        return 0
      var m = boxes[0].y
      for (var i = 1; i < boxes.length; i++)
        if (boxes[i].y < m)
          m = boxes[i].y
      return m
    }
    readonly property real maxX: {
      if (boxes.length === 0)
        return 1
      var m = boxes[0].x + boxes[0].w
      for (var i = 1; i < boxes.length; i++)
        if (boxes[i].x + boxes[i].w > m)
          m = boxes[i].x + boxes[i].w
      return m
    }
    readonly property real maxY: {
      if (boxes.length === 0)
        return 1
      var m = boxes[0].y + boxes[0].h
      for (var i = 1; i < boxes.length; i++)
        if (boxes[i].y + boxes[i].h > m)
          m = boxes[i].y + boxes[i].h
      return m
    }
    readonly property real spanX: Math.max(1, maxX - minX)
    readonly property real spanY: Math.max(1, maxY - minY)
    // 0.97: a little headroom so a box near the fitted bounding box's own
    // edge isn't rendered flush against the canvas frame — kept slight
    // since dragging no longer needs to route around other boxes (see
    // onPositionChanged/onReleased below).
    readonly property real pxPerUnit: Math.min(diagram.width / diagram.spanX, diagram.height / diagram.spanY) * 0.97
    readonly property real contentWidth: spanX * pxPerUnit
    readonly property real contentHeight: spanY * pxPerUnit

    // Logical (Hyprland-coordinate) rects of every box except the one being
    // dragged — the snap/collision targets for whichever box is moving.
    // boxes[].x/y are already info.x/info.y verbatim (see `boxes` above),
    // so this needs no screen-space conversion at all.
    function otherLogicalRects(excludeName) {
      var out = []
      for (var i = 0; i < boxes.length; i++) {
        if (boxes[i].name === excludeName)
          continue
        out.push({
          x: boxes[i].x,
          y: boxes[i].y,
          w: boxes[i].w,
          h: boxes[i].h
        })
      }
      return out
    }

    // logicalX/Y are already the final, snapped, integer position — no
    // conversion happens here, so nothing can drift from what was decided
    // (and displayed) during the drag.
    function commitDrag(name, logicalX, logicalY) {
      var info = root.transaction.draft.find(function (m) {
        return m.name === name
      })
      if (!info)
        return
      if (logicalX === info.x && logicalY === info.y)
        return
      root.moveMonitor(name, logicalX, logicalY)
    }

    Item {
      id: diagramInner
      width: diagram.contentWidth
      height: diagram.contentHeight
      anchors.centerIn: parent

      Repeater {
        model: diagram.boxes

        ArrangementBox {
          required property var modelData
          canvas: diagram
          info: modelData
        }
      }
    }
  }

  // One draggable box in the ArrangementDiagram canvas. Position is
  // base (from the model) plus an in-flight drag offset, rather than a
  // direct binding to screen coordinates — dragging never overwrites the
  // model-derived base, so there's nothing to re-bind once the drag ends
  // and the real position (read back from hyprctl) flows into `info`.
  component ArrangementBox: Rectangle {
    id: box
    required property var info
    property ArrangementDiagram canvas

    readonly property real baseX: (info.x - canvas.minX) * canvas.pxPerUnit
    readonly property real baseY: (info.y - canvas.minY) * canvas.pxPerUnit
    property real dragDeltaX: 0
    property real dragDeltaY: 0

    x: baseX + dragDeltaX
    y: baseY + dragDeltaY
    width: Math.max(2, info.w * canvas.pxPerUnit - 2)
    height: Math.max(2, info.h * canvas.pxPerUnit - 2)
    radius: Style.space(6)
    color: info.focused ? Qt.tint(Color.popups.background, Qt.alpha(root.foreground, 0.18)) : Color.popups.background
    border.width: dragArea.dragging ? 2 : 1
    border.color: dragArea.dragging || activeFocus || info.focused ? root.foreground : root.divider
    z: dragArea.dragging ? 10 : 1
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: info.label
    Accessible.onPressAction: selectDisplay()
    function selectDisplay() {
      var monitor = root.transaction.draft.find(function (m) {
        return m.name === info.name
      })
      if (monitor)
        root.selectMonitor(monitor.id)
    }
    Keys.onPressed: function (event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Space) {
        selectDisplay()
        event.accepted = true
        return
      }
      var step = event.modifiers & Qt.ShiftModifier ? 10 : 1
      var dx = event.key === Qt.Key_Left ? -step : event.key === Qt.Key_Right ? step : 0
      var dy = event.key === Qt.Key_Up ? -step : event.key === Qt.Key_Down ? step : 0
      if (dx || dy) {
        root.moveMonitor(info.name, info.x + dx, info.y + dy)
        event.accepted = true
      }
    }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: box.info.number + "\n" + box.info.label
      color: root.foreground
      font.family: root.panelFontFamily
      font.pixelSize: Style.space(12)
      elide: Text.ElideRight
      width: parent.width - Style.space(8)
      horizontalAlignment: Text.AlignHCenter
    }

    MouseArea {
      id: dragArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.SizeAllCursor

      property bool dragging: false
      property real startCanvasX: 0
      property real startCanvasY: 0
      property real startLogicalX: 0
      property real startLogicalY: 0
      // The authoritative in-flight position, in Hyprland's own logical
      // coordinates. Snapping and overlap checks happen entirely here —
      // never in screen space — so a snap that lands flush against a
      // neighbor's edge is an exact integer match, not a value that only
      // looks flush at diagram scale and drifts by a pixel once divided
      // back out of pxPerUnit. That drift was exactly why two displays
      // that appeared to snap together were still overlapping underneath.
      property real curLogicalX: 0
      property real curLogicalY: 0

      // Mapped into box.parent (diagramInner), which never moves — mapping
      // into the box itself would compare positions in a frame that shifts
      // by exactly the amount already dragged, corrupting the delta.
      onPressed: function (mouse) {
        var p = mapToItem(box.parent, mouse.x, mouse.y)
        startCanvasX = p.x
        startCanvasY = p.y
        startLogicalX = box.info.x
        startLogicalY = box.info.y
        curLogicalX = startLogicalX
        curLogicalY = startLogicalY
        dragging = true
        root.arrangementDragActive = true
      }

      onPositionChanged: function (mouse) {
        if (!dragging)
          return
        var unit = box.canvas.pxPerUnit
        var p = mapToItem(box.parent, mouse.x, mouse.y)
        var rawX = startLogicalX + (p.x - startCanvasX) / unit
        var rawY = startLogicalY + (p.y - startCanvasY) / unit

        var snap = Style.space(8) / unit
        var others = box.canvas.otherLogicalRects(box.info.name)
        var w = box.info.w, h = box.info.h
        var bestDX = null, bestDY = null

        for (var i = 0; i < others.length; i++) {
          var o = others[i]
          var candidatesX = [o.x + o.w / 2 - rawX - w / 2, o.x - rawX, (o.x + o.w) - (rawX + w), o.x - (rawX + w), (o.x + o.w) - rawX]
          for (var cx = 0; cx < candidatesX.length; cx++) {
            var dx = candidatesX[cx]
            if (Math.abs(dx) <= snap && (bestDX === null || Math.abs(dx) < Math.abs(bestDX)))
              bestDX = dx
          }
          var candidatesY = [o.y + o.h / 2 - rawY - h / 2, o.y - rawY, (o.y + o.h) - (rawY + h), o.y - (rawY + h), (o.y + o.h) - rawY]
          for (var cy = 0; cy < candidatesY.length; cy++) {
            var dy = candidatesY[cy]
            if (Math.abs(dy) <= snap && (bestDY === null || Math.abs(dy) < Math.abs(bestDY)))
              bestDY = dy
          }
        }
        if (bestDX !== null)
          rawX += bestDX
        if (bestDY !== null)
          rawY += bestDY

        // Round to whole logical pixels now — Hyprland positions are
        // integers, and this is what makes a snap land exactly flush
        // rather than a hair off. No overlap check here: real display-
        // arrangement UIs (GNOME, Windows) let you drag straight across
        // another display mid-gesture — blocking that made it effectively
        // impossible to swing one display from one side of another to the
        // far side, since there was rarely enough spare canvas room to
        // route all the way around it. Overlap is only resolved once, on
        // drop (onReleased).
        curLogicalX = Math.round(rawX)
        curLogicalY = Math.round(rawY)
        box.dragDeltaX = (curLogicalX - box.info.x) * unit
        box.dragDeltaY = (curLogicalY - box.info.y) * unit
      }

      onCanceled: {
        dragging = false
        root.arrangementDragActive = false
        box.dragDeltaX = 0
        box.dragDeltaY = 0
      }

      onReleased: {
        var monitorName = box.info.name
        dragging = false
        root.arrangementDragActive = false
        // Nudge clear of any overlap only now, at the drop point, using
        // the same logical-coordinate resolver used by draft validation.
        var others = box.canvas.otherLogicalRects(box.info.name)
        var resolved = Model.resolveMonitorOverlap({
          x: curLogicalX,
          y: curLogicalY,
          w: box.info.w,
          h: box.info.h
        }, others)
        box.canvas.commitDrag(box.info.name, resolved.x, resolved.y)
        box.dragDeltaX = 0
        box.dragDeltaY = 0
        // Selecting rebuilds the diagram's delegates, so wait until release ends.
        Qt.callLater(function () {
          var monitor = root.transaction.draft.find(function (m) {
            return m.name === monitorName
          })
          if (monitor)
            root.selectMonitor(monitor.id)
        })
      }
    }
  }
}
