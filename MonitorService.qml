pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "kit"
import "Model.js" as Model

// Display state shared by every Foamy Monitor bar instance (4.5 draws one
// bar per monitor). Nothing here polls while every popup is closed:
//   - display_transaction.py status runs once when the first panel joins,
//     when its state file changes (FileView watch: another popup, the trial
//     worker), on Hyprland output events, every 5 s while a popup is open and
//     every second during a trial (a safety net for the file watch);
//   - brightness is read only for an open popup, the wheel or IPC, one
//     DDC/backlight job at a time for the whole shell;
//   - the FluxCast scan and cast run here once and stop when the last panel
//     goes away (plugin disabled or removed) or the shell reloads.
// Panels join FoamyMember scope "monitor"; an open popup raises demand.
Singleton {
  id: root

  readonly property int members: FoamyShared.memberCount("monitor")
  readonly property bool demanded: FoamyShared.demandCount("monitor") > 0
  // Held for a moment after the last panel leaves, so a 4.5 bar rebuild
  // (an output added or removed) does not stop a cast.
  property bool active: false
  onMembersChanged: {
    if (members > 0) {
      releaseTimer.stop()
      if (!active) { active = true; refresh() }
    } else if (active) {
      releaseTimer.restart()
    }
  }

  function localPath(url) { return decodeURIComponent(String(url).replace(/^file:\/\//, "")) }
  readonly property string bridge: localPath(Qt.resolvedUrl("display_transaction.py"))
  readonly property string fluxCastBridge: localPath(Qt.resolvedUrl("fluxcast_bridge.py"))

  // ---- Display transaction ------------------------------------------------
  property var transaction: ({ phase: "idle", base: [], draft: [] })
  property var liveMonitors: []
  property var gtkScale: ({ base: null, value: null, error: "" })
  property string statePath: ""
  property string error: ""
  property bool displayChangesSaved: false
  property bool arrangementDragActive: false
  property string deferredResult: ""
  property var commands: []
  property int statusRuns: 0
  readonly property bool testing: transaction.phase === "testing"
  readonly property bool busy: ["applying", "testing", "saving", "reverting"].indexOf(transaction.phase) >= 0
  readonly property string focusedMonitor: {
    var monitor = Hyprland.focusedMonitor
    if (monitor && monitor.name) return String(monitor.name)
    var live = liveMonitors.find(function(m) { return m.focused })
    return live ? live.name : ""
  }
  readonly property int changeCount: transaction.draft.reduce(function(sum, m) {
    return sum + root.changesFor(m).length
  }, 0) + (gtkScale.base !== gtkScale.value ? 1 : 0)
  onChangeCountChanged: if (changeCount > 0) displayChangesSaved = false
  readonly property bool disconnectedDraft: transaction.draft.some(function(m) { return !m.connected })

  function changesFor(monitor) {
    return Model.changedFields(transaction.base.find(function(m) { return m.id === monitor.id }), monitor)
  }

  // Nothing runs without a panel (preview mocks set the state directly).
  function enqueue(action, payload) {
    if (!active) return
    if (action === "status" && (commandProc.running || commands.length || arrangementDragActive)) return
    commands = commands.concat([{ action: action, payload: payload || {} }])
    runNext()
  }
  function runNext() {
    if (commandProc.running || !commands.length) return
    var next = commands[0]
    commands = commands.slice(1)
    commandProc.action = next.action
    commandProc.payload = next.payload
    commandProc.command = ["python3", bridge, next.action]
    if (next.action === "status") statusRuns++
    commandProc.running = true
  }
  function statusSoon() { if (active) statusDebounce.restart() }
  function refresh() {
    enqueue("status")
    if (active && demanded && !cursorInfoProc.running) cursorInfoProc.running = true
  }
  function acceptResult(text) {
    if (arrangementDragActive) { deferredResult = text; return }
    try {
      var result = JSON.parse(text)
      if (!result.ok) { error = result.error; return }
      // A clean draft alone is not proof of a save: wait for Keep to finish successfully.
      if (busy && result.state.phase === "idle")
        displayChangesSaved = result.state.decision === "keep" && !result.state.error && result.state.token === transaction.token
      if (JSON.stringify(transaction) !== JSON.stringify(result.state)) transaction = result.state
      if (JSON.stringify(liveMonitors) !== JSON.stringify(result.live)) liveMonitors = result.live
      var gtk = result.gtkScale || { base: null, value: null, error: "Could not read GTK scale" }
      if (JSON.stringify(gtkScale) !== JSON.stringify(gtk)) gtkScale = gtk
      if (result.statePath && result.statePath !== statePath) statePath = result.statePath
      if (commandProc.action !== "status") error = ""
    } catch (e) {
      error = "Could not read display settings: " + e
    }
  }
  onArrangementDragActiveChanged: if (!arrangementDragActive && deferredResult) {
    var result = deferredResult
    deferredResult = ""
    Qt.callLater(function() { root.acceptResult(result) })
  }

  property Process commandProc: Process {
    property string action: ""
    property var payload: ({})
    stdinEnabled: true
    onStarted: write(JSON.stringify(payload) + "\n")
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.acceptResult(text) }
    stderr: StdioCollector { id: commandError; waitForEnd: true }
    onExited: function(code) {
      if (code && commandError.text) root.error = String(commandError.text).trim()
      Qt.callLater(root.runNext)
    }
  }

  // Draft and trial changes from any instance (or the detached worker) land
  // in the helper's state file; re-read status only when its revision moves.
  property FileView stateFile: FileView {
    path: root.active ? root.statePath : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var state = JSON.parse(text())
        if (state.revision !== root.transaction.revision) root.statusSoon()
      } catch (e) {}
    }
  }

  property Connections hyprlandEvents: Connections {
    target: Hyprland
    enabled: root.active
    function onRawEvent(event) { if (event && Model.isLayoutEvent(event.name)) root.statusSoon() }
  }

  property Timer statusDebounce: Timer { interval: 150; onTriggered: root.enqueue("status") }
  property Timer pollTimer: Timer {
    interval: root.busy ? 1000 : 5000
    repeat: true
    running: root.active && (root.busy || root.demanded)
    onTriggered: root.refresh()
  }
  property Timer releaseTimer: Timer {
    interval: 3000
    onTriggered: if (root.members === 0) root.teardown()
  }

  // ---- Brightness (DDC or backlight via omarchy-brightness-display) -------
  property var brightness: ({})        // name -> { available, percent }
  property var brightnessWrites: ({})  // name -> percent, latest wins
  property var brightnessReads: []     // names
  property var brightnessAfterRead: ({}) // name -> { delta } or { value }, applied once known
  signal brightnessStepped(var requester, string monitor, int percent)
  property var _stepRequester: ({})

  function brightnessFor(name) { return brightness[name] || null }
  function readBrightness(name) {
    if (!active || !name || brightnessReads.indexOf(name) !== -1 || brightnessWrites[name] !== undefined) return
    brightnessReads = brightnessReads.concat([name])
    pumpBrightness()
  }
  // Every reading carries its time: a cached level older than a wheel burst is
  // re-read before a relative step (laptop keys, other apps and the monitor's
  // own buttons change it while every popup is closed).
  function _store(name, value) {
    var next = Object.assign({}, brightness)
    next[name] = { available: value.available, percent: value.percent, at: Date.now() }
    brightness = next
  }
  function setBrightness(name, percent) {
    var known = brightness[name]
    if (!name || !known || !known.available) return -1
    var value = Model.clampBrightness(percent)
    _store(name, { available: true, percent: value })
    var writes = Object.assign({}, brightnessWrites)
    writes[name] = value
    brightnessWrites = writes
    brightnessDebounce.restart()
    return value
  }
  // Wheel and IPC: step (delta) or set (value) a display that may not have
  // been read yet. Returns the new percent, -1 when unavailable, or 0 when
  // queued behind a read; brightnessStepped(requester, …) follows a queued step.
  function changeBrightness(name, change, requester) {
    var known = brightness[name]
    if (!name) return -1
    var absolute = change.value !== undefined
    if (known && (Model.brightnessFresh(known, Date.now()) || (absolute && known.available))) {
      if (!known.available) return -1
      return setBrightness(name, absolute ? change.value : known.percent + change.delta)
    }
    var after = Object.assign({}, brightnessAfterRead)
    var earlier = after[name]
    // Wheel notches that arrive before the first read add up.
    after[name] = earlier && earlier.delta !== undefined && change.delta !== undefined ? { delta: earlier.delta + change.delta } : change
    brightnessAfterRead = after
    var requesters = Object.assign({}, _stepRequester)
    requesters[name] = requester || null
    _stepRequester = requesters
    readBrightness(name)
    return 0
  }
  function pumpBrightness() {
    if (!active || brightnessProc.running) return
    var job = Model.nextBrightnessJob(brightnessWrites, brightnessReads, brightnessDebounce.running)
    if (!job) return
    if (job.kind === "write") {
      var writes = Object.assign({}, brightnessWrites)
      delete writes[job.name]
      brightnessWrites = writes
      brightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", job.name, job.value + "%"]
    } else {
      brightnessReads = brightnessReads.filter(function(n) { return n !== job.name })
      brightnessProc.command = ["omarchy-brightness-display", "--monitor", job.name]
    }
    brightnessProc.job = job
    brightnessProc.running = true
  }
  property Timer brightnessDebounce: Timer { interval: 150; onTriggered: root.pumpBrightness() }
  property Process brightnessProc: Process {
    property var job: null
    stdout: StdioCollector { id: brightnessOutput; waitForEnd: true }
    stderr: StdioCollector { id: brightnessError; waitForEnd: true }
    onExited: function(code) {
      var job = root.brightnessProc.job
      if (job && job.kind === "write" && code) {
        root.error = String(brightnessError.text).trim() || "Could not set brightness"
      } else if (job && job.kind === "read" && root.brightnessWrites[job.name] === undefined) {
        root._store(job.name, Model.parseBrightness(code, brightnessOutput.text))
        var change = root.brightnessAfterRead[job.name]
        if (change) {
          var after = Object.assign({}, root.brightnessAfterRead)
          delete after[job.name]
          root.brightnessAfterRead = after
          var percent = root.changeBrightness(job.name, change, null)
          root.brightnessStepped(root._stepRequester[job.name] || null, job.name, percent)
        }
      }
      Qt.callLater(root.pumpBrightness)
    }
  }

  // ---- Advanced: text size, cursor size ------------------------------------
  property int cursorSize: 24
  readonly property bool advancedBusy: advancedProc.running
  function setCursorSize(value) {
    if (!active || advancedProc.running) return
    advancedProc.command = ["bash", "-c", 'theme=$(gsettings get org.gnome.desktop.interface cursor-theme); theme=${theme//\'/}; gsettings set org.gnome.desktop.interface cursor-size "$1" && hyprctl setcursor "$theme" "$1"', "cursor-size", String(Number(value))]
    advancedProc.running = true
  }
  function setTextSize(value) {
    if (!active || advancedProc.running) return
    advancedProc.command = ["omarchy-display-text-size", String(Number(value))]
    advancedProc.running = true
  }
  property Process cursorInfoProc: Process {
    command: ["gsettings", "get", "org.gnome.desktop.interface", "cursor-size"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var n = Number(String(text).trim())
        if (isFinite(n) && n > 0) root.cursorSize = n
      }
    }
  }
  property Process advancedProc: Process {
    stderr: StdioCollector { id: advancedError; waitForEnd: true }
    onExited: function(code) {
      if (code) root.error = String(advancedError.text).trim() || "Could not update advanced settings"
      root.refresh()
    }
  }

  // ---- Identify -----------------------------------------------------------
  property bool identifyVisible: false
  function showIdentify() { identifyVisible = true; identifyTimer.restart() }
  property Timer identifyTimer: Timer { interval: 2500; onTriggered: root.identifyVisible = false }

  // ---- Wireless displays (FluxCast) ---------------------------------------
  property var wirelessPeers: []
  property var missingPackages: []
  property string wirelessScanState: "idle"
  property bool wirelessCacheValid: false
  property string wirelessError: ""
  property string castPhase: "idle"
  property string castDetail: ""
  property string castTargetName: ""
  property string castMonitor: ""
  property bool castExpectedStop: false
  property bool wirelessScanExpectedStop: false
  // The tab that wants scanning (an open popup on the Wireless tab).
  property bool wirelessWanted: false
  readonly property bool scanRunning: scanProc.running
  readonly property bool scanning: scanProc.running || dependenciesProc.running
  readonly property bool castRunning: castProc.running
  readonly property bool activelyCasting: castRunning && castPhase === "casting"

  function checkWireless(force) {
    if (!active || dependenciesProc.running || scanProc.running || castProc.running || (wirelessCacheValid && !force)) return
    dependenciesProc.running = true
  }
  function startWirelessScan() {
    if (!active || scanProc.running || castProc.running || missingPackages.length) return
    wirelessScanExpectedStop = false
    wirelessCacheValid = false
    wirelessPeers = []
    wirelessError = ""
    wirelessScanState = "scanning"
    scanProc.command = ["python3", fluxCastBridge, "scan", "--timeout", "8"]
    scanProc.running = true
  }
  function cancelWirelessScan() {
    if (!scanProc.running || wirelessScanExpectedStop) return
    wirelessScanExpectedStop = true
    scanProc.signal(15)
  }
  function connectWirelessPeer(peer, label, monitor) {
    if (!active || !peer || scanProc.running || castProc.running || missingPackages.length) return
    if (!monitor) { wirelessError = "No enabled display"; return }
    castTargetName = label
    castMonitor = monitor
    castExpectedStop = false
    castPhase = "starting"
    castDetail = ""
    wirelessError = ""
    castProc.command = ["python3", fluxCastBridge, "cast", "--peer", peer.address, "--monitor", monitor,
      "--output-res", "1920x1080", "--fps", "30", "--bitrate", "4M", "--timeout", "8"]
    castProc.running = true
  }
  function stopCast() {
    if (!castProc.running || castExpectedStop) return
    castExpectedStop = true
    castPhase = "stopping"
    castProc.signal(15)
    castStopWatchdog.restart()
  }
  function applyCastEvent(line) {
    var event = Model.parseFluxCastEvent(line)
    if (!event || event.type !== "phase") return
    castPhase = String(event.phase)
    castDetail = String(event.detail || "")
    if (castPhase === "error") wirelessError = castDetail
  }
  // A popup closed: forget the search and stop a scan nobody watches.
  function releaseWireless() {
    wirelessCacheValid = false
    cancelWirelessScan()
  }

  property Process dependenciesProc: Process {
    command: ["python3", root.fluxCastBridge, "check"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.parseFluxCastScan(text)
        root.missingPackages = result.missingPackages || []
        root.wirelessError = result.error
        if (root.missingPackages.length) root.wirelessScanState = "missing"
        else if (!result.error && root.wirelessWanted) root.startWirelessScan()
      }
    }
  }
  property Timer dependencyRetry: Timer {
    interval: 10000
    repeat: true
    running: root.wirelessWanted && root.missingPackages.length > 0
    onTriggered: root.checkWireless(true)
  }
  property Process scanProc: Process {
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.wirelessScanExpectedStop) return
        var result = Model.parseFluxCastScan(text)
        root.wirelessPeers = result.peers
        root.wirelessError = result.error
        root.missingPackages = result.missingPackages || []
        root.wirelessScanState = result.error ? "error" : result.peers.length ? "results" : "empty"
        root.wirelessCacheValid = root.wirelessWanted
      }
    }
    onExited: function(code) {
      if (root.wirelessScanExpectedStop) {
        root.wirelessScanExpectedStop = false
        root.wirelessScanState = "idle"
        // A quick reopen may have happened before the old process stopped.
        if (root.wirelessWanted) Qt.callLater(root.checkWireless)
        return
      }
      if (root.wirelessScanState === "scanning") {
        root.wirelessScanState = "error"
        root.wirelessCacheValid = root.wirelessWanted
        root.wirelessError = "Wireless display scan failed"
      }
    }
  }
  property Process castProc: Process {
    stdout: SplitParser { onRead: function(line) { root.applyCastEvent(line) } }
    onExited: function(code) {
      root.castStopWatchdog.stop()
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
  property Timer castStopWatchdog: Timer {
    interval: 12000
    onTriggered: if (root.castProc.running) root.castProc.signal(15)
  }

  // ---- Lifecycle ----------------------------------------------------------
  // The last panel is gone (plugin disabled or removed) or the shell is
  // reloading. Quickshell SIGKILLs a destroyed Process, so ask the bridges to
  // stop first; FluxCast also stops on its own when its bridge dies
  // (PR_SET_PDEATHSIG in fluxcast_bridge.py).
  property int teardowns: 0
  function teardown() {
    teardowns++
    active = false
    statusDebounce.stop()
    commands = []
    brightnessReads = []
    brightnessWrites = ({})
    brightnessAfterRead = ({})
    identifyVisible = false
    wirelessWanted = false
    if (castProc.running) { castExpectedStop = true; castProc.signal(15) }
    if (scanProc.running) { wirelessScanExpectedStop = true; scanProc.signal(15) }
  }
  Component.onDestruction: teardown()
}
