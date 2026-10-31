import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "harness"
import "plugin" as Monitor
import "plugin/kit"

// Foamy Monitor under a real host shell, offscreen, with fake hyprctl,
// brightness and FluxCast (tests/fakebin.py): three bar instances (three
// monitors), one leader and one startup status for all of them, state-file
// and Hyprland-event refreshes with every popup closed, the lazy popup body,
// the single keyboard cursor, serialised brightness, translations and RTL,
// and the teardown that stops FluxCast when the last panel goes.
ShellRoot {
  id: shell
  readonly property string host: Quickshell.env("FOAMY_HOST")
  readonly property string lang: Quickshell.env("FOAMY_LANG") || "en"
  property int checks: 0
  property int failures: 0
  property int panelCount: 3
  property int runsBefore: 0

  function check(ok, label) {
    checks++
    if (!ok) { failures++; console.log("FOAMY FAIL " + host + "/" + lang + " " + label) }
  }
  function eq(actual, expected, label) {
    check(actual === expected, label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
  }
  FoamyCursor { id: keys }
  function key(view, text) { keys.emitTextKey(view, text) }
  function panel(i) { return panels.itemAt(i) }
  readonly property var service: Monitor.MonitorService

  FloatingWindow {
    implicitWidth: 1920
    implicitHeight: 1080
    color: "black"
    Row {
      y: 4
      x: 1200
      spacing: 40
      Repeater {
        id: panels
        model: shell.panelCount
        Monitor.Panel { bar: mockBar }
      }
    }
  }

  MockBar {
    id: mockBar
    moduleName: "foamy.monitor"
    property var summoned: []
    shell: QtObject {
      function updateEntryInline(id, settings) { return true }
      function summon(id, payload) { mockBar.summoned = mockBar.summoned.concat([{ id: id, payload: JSON.parse(payload) }]); return true }
    }
  }

  // Another bar instance or the trial worker writing the shared state file.
  Process {
    id: external
    property string payload: ""
    stdinEnabled: true
    onStarted: write(payload + "\n")
  }

  Component.onCompleted: stepOne.start()

  function setPhase(phase) {
    sh("python3 - '" + service.statePath + "' " + phase + " <<'PY'\nimport json, sys, time\np, phase = sys.argv[1], sys.argv[2]\ns = json.load(open(p))\ns.update(phase=phase, deadline=time.time() + 15 if phase == 'testing' else 0, token='runtime-trial')\ns['revision'] = s.get('revision', 0) + 1\njson.dump(s, open(p, 'w'))\nPY")
  }
  function leaderPanel() {
    for (var i = 0; i < panelCount; i++) if (panel(i).member.isLeader) return panel(i)
    return null
  }
  function openCount() {
    var count = 0
    for (var i = 0; i < panelCount; i++) if (panel(i).opened) count++
    return count
  }
  function leaders() {
    var count = 0
    for (var i = 0; i < panelCount; i++) if (panel(i).member.isLeader) count++
    return count
  }

  Timer {
    id: stepOne
    interval: 2500
    onTriggered: {
      eq(shell.leaders(), 1, "one leader across three bar instances")
      eq(shell.service.members, 3, "three members")
      eq(panel(0).barGlyph.codePointAt(0), Quickshell.screens.length > 1 ? 0xf037a : 0xf0379, "bar glyph survives as an escape")
      eq(shell.service.statusRuns, 1, "one startup status for every instance")
      eq(shell.service.liveMonitors.length, 3, "three displays read")
      check(shell.service.statePath.indexOf("/state.json") > 0, "state file reported: " + shell.service.statePath)
      eq(panel(0).popup.bodyItem, null, "popup body is lazy")
      eq(shell.service.demanded, false, "no demand while closed")
      eq(Object.keys(shell.service.brightness).length, 0, "no brightness probe at startup")
      console.log("FOAMY READY")
      shell.runsBefore = shell.service.statusRuns
      var draft = shell.service.transaction.draft
      external.payload = JSON.stringify({ id: draft[1].id, changes: { x: 4000 } })
      external.command = ["python3", shell.service.bridge, "patch"]
      external.running = true
      stepTwo.start()
    }
  }

  Timer {
    id: stepTwo
    interval: 1500
    onTriggered: {
      eq(shell.service.transaction.draft[1].x, 4000, "a draft written elsewhere arrives through the file watch")
      check(shell.service.statusRuns > shell.runsBefore, "the file watch ran status with every popup closed")
      eq(shell.service.changeCount, 1, "one unsaved change")
      // The helper replaces the file atomically; the watch must survive that.
      external.payload = JSON.stringify({ id: shell.service.transaction.draft[1].id, changes: { x: 4100 } })
      external.running = true
      stepTwoB.start()
    }
  }

  Timer {
    id: stepTwoB
    interval: 1500
    onTriggered: {
      eq(shell.service.transaction.draft[1].x, 4100, "a second write arrives too (watch survives the atomic replace)")
      shell.runsBefore = shell.service.statusRuns
      shell.service.hyprlandEvents.onRawEvent({ name: "focusedmon" })
      shell.service.hyprlandEvents.onRawEvent({ name: "workspacev2" })
      stepThree.start()
    }
  }

  Timer {
    id: stepThree
    interval: 600
    onTriggered: {
      eq(shell.service.statusRuns, shell.runsBefore, "focus and workspace events do not run status")
      shell.service.hyprlandEvents.onRawEvent({ name: "monitoraddedv2" })
      shell.service.hyprlandEvents.onRawEvent({ name: "configreloaded" })
      stepFour.start()
    }
  }

  Timer {
    id: stepFour
    interval: 900
    onTriggered: {
      eq(shell.service.statusRuns, shell.runsBefore + 1, "output events run one debounced status")
      // An output change while a status run is in flight (it already read the
      // outputs): the event's refresh must run after it, not be dropped.
      shell.runsBefore = shell.service.statusRuns
      shell.sh("printf 1 > \"$FOAMY_CALLS.hyprdelay\"")
      inflightA.start()
    }
  }

  Timer {
    id: inflightA
    interval: 300
    onTriggered: {
      shell.service.refresh()
      eq(shell.service.commandProc.running, true, "a slow status run is in flight")
      inflightB.start()
    }
  }
  Timer {
    id: inflightB
    interval: 300
    onTriggered: {
      shell.sh("python3 - <<'PY'\nimport json, os\np = os.path.join(os.environ['FOAMY_FAKEBIN'], 'monitors.json')\nrows = json.load(open(p))\nrows[2]['y'] = 100\njson.dump(rows, open(p, 'w'))\nPY")
      inflightC.start()
    }
  }
  Timer {
    id: inflightC
    interval: 300
    onTriggered: {
      eq(shell.service.commandProc.running, true, "still in flight when the event arrives")
      shell.service.hyprlandEvents.onRawEvent({ name: "monitoraddedv2" })
      inflightD.start()
    }
  }
  Timer {
    id: inflightD
    interval: 3500
    onTriggered: {
      eq(shell.service.liveMonitors[2].y, 100, "the change made during the run arrives")
      eq(shell.service.statusRuns, shell.runsBefore + 2, "exactly one follow-up run")
      eq(shell.service.statusPending, false, "nothing left pending")
      shell.sh("rm -f \"$FOAMY_CALLS.hyprdelay\"")
      panel(0).open()
      stepFive.start()
    }
  }

  Timer {
    id: stepFive
    interval: 900
    onTriggered: {
      var first = panel(0)
      var view = first.popup.bodyItem
      check(view !== null, "body built on open")
      eq(shell.service.demanded, true, "open popup raises demand")
      if (!view) { shell.finish(); return }
      eq(view.selectedMonitor, shell.service.transaction.draft[0].id, "the focused display is selected")
      eq(view.brightnessAvailable, true, "brightness read for the open popup")
      eq(view.brightnessPercent, 50, "brightness value")
      eq(view.cursorKey, "", "no cursor highlight on open")
      view.moveRequested(0, 1)
      eq(view.cursorKey, "tab:Display", "first move lands on the tabs")
      view.moveRequested(1, 0)
      eq(view.activeTab, "Advanced", "l switches tab")
      eq(view.cursorKey, "tab:Advanced", "the cursor follows the tab")
      view.moveRequested(0, 1)
      eq(view.cursorKey, "textSize", "j walks into the tab")
      check(view.stops.indexOf("save") > 0 && view.stops.indexOf("discard") > 0, "pending change adds Discard and Save")
      shell.key(view, "w")
      eq(view.activeTab, "Wireless", "w opens Wireless")
      eq(shell.service.wirelessWanted, true, "the Wireless tab wants a scan")
      view.setTab("Display")
      eq(shell.service.wirelessWanted, false, "leaving Wireless releases it")
      view.place("box:1")
      shell.key(view, "m")
      check(view.moving !== "", "m picks up the display under the cursor")
      var before = shell.service.transaction.draft.find(function(m) { return m.name === view.moving }).x
      // Three presses before the helper answers still add up to 30 px.
      view.moveRequested(1, 0)
      view.moveRequested(1, 0)
      view.moveRequested(1, 0)
      shell.runsBefore = before
      view.activateRequested()
      eq(view.moving, "", "Enter drops it")
      eq(view.LayoutMirroring.enabled, shell.lang === "ar", "popup body mirrors in RTL only")
      eq(FoamyI18n.tn("%1 unsaved changes", 1), shell.lang === "no" ? "1 ulagret endring" : "1 unsaved change", "plural")
      eq(FoamyI18n.t("Settings"), shell.lang === "no" ? "Innstillinger" : "Settings", "settings title translated")
      shell.key(view, "s")
      eq(first.editingSettings, true, "s opens Settings")
      eq(view.blocked, true, "settings page owns the keys")
      first.closeSettings()
      eq(view.blocked, false, "back from Settings")
      view.closeRequested()
      eq(first.opened, false, "Esc closes")
      // IPC `settings` as the first action: the lazy body is built straight
      // into Settings and Back must own the keys.
      panel(1).openSettings()
      // Brightness from three bars at once: one DDC job at a time.
      for (var i = 0; i < 3; i++) shell.service.changeBrightness(shell.service.liveMonitors[i].name, { delta: 5 }, panel(i))
      eq(first.brightnessIpc("abc"), "error: expected a percentage such as 40, +5 or -5", "IPC rejects junk")
      stepSix.start()
    }
  }

  Timer {
    id: stepSix
    interval: 1500
    onTriggered: {
      var draft = shell.service.transaction.draft
      eq(draft.find(function(m) { return m.name === "DP-1" }).x, shell.runsBefore + 30, "three quick arrows nudge the display by 30 px")
      eq(shell.service.brightness["DP-2"].percent, 55, "a wheel step before the first read lands after it")
      check(mockBar.summoned.length >= 1 && mockBar.summoned[0].id === "omarchy.osd" && mockBar.summoned[0].payload.icon === "brightness",
        "the wheel shows the Omarchy OSD: " + JSON.stringify(mockBar.summoned))
      eq(shell.service.brightnessProc.running, false, "brightness queue drained")
      var second = panel(1).popup.bodyItem
      check(second !== null && second.editing, "settings opened on a fresh panel")
      check(second !== null && second.settingsBackFocused, "Back has focus when Settings is the first view")
      panel(1).close()
      // The level changed elsewhere (laptop keys, the monitor's buttons) while
      // every popup was closed: a wheel step after the burst re-reads first.
      external.payload = ""
      external.command = ["sh", "-c", "printf 80 > \"$FOAMY_CALLS.brightness\""]
      external.running = true
      var aged = Object.assign({}, shell.service.brightness)
      aged["DP-2"] = { available: true, percent: 55, at: Date.now() - 10000 }
      shell.service.brightness = aged
      stepSixB.start()
    }
  }

  Timer {
    id: stepSixB
    interval: 400
    onTriggered: {
      eq(shell.service.changeBrightness("DP-2", { delta: 5 }, panel(2)), 0, "a stale level is read again before stepping")
      stepSixC.start()
    }
  }

  Timer {
    id: stepSixC
    interval: 1200
    onTriggered: {
      eq(shell.service.brightness["DP-2"].percent, 85, "the step lands on the fresh level (80 + 5)")
      eq(shell.service.changeBrightness("DP-2", { delta: 5 }, panel(2)), 90, "steps within the burst reuse it")
      // An explicit level queued behind a read keeps later steps relative to it.
      var unknown = Object.assign({}, shell.service.brightness)
      delete unknown["DP-1"]
      shell.service.brightness = unknown
      eq(shell.service.changeBrightness("DP-1", { value: 40 }, null), 0, "an unread display queues the level")
      eq(shell.service.changeBrightness("DP-1", { delta: 5 }, null), 0, "and the following step")
      // A step waiting on a stale reading, then an explicit level: the level wins for good.
      var stale = Object.assign({}, shell.service.brightness)
      stale["eDP-1"] = { available: true, percent: 30, at: Date.now() - 10000 }
      shell.service.brightness = stale
      eq(shell.service.changeBrightness("eDP-1", { delta: 5 }, null), 0, "a step on a stale reading waits for a read")
      eq(shell.service.changeBrightness("eDP-1", { value: 40 }, null), 40, "an explicit level is written at once")
      eq(shell.service.brightnessAfterRead["eDP-1"], undefined, "and supersedes the waiting step")
      lifeA.start()
    }
  }

  // ---- Per-view demand: popup close, a bar removed (unplug), hot-plug grace ----
  Timer {
    id: lifeA
    interval: 1200
    onTriggered: {
      eq(shell.service.brightness["DP-1"].percent, 45, "40 then +5 lands on 45, not the hardware level + 5")
      eq(shell.service.brightness["eDP-1"].percent, 40, "the explicit level stays after the read lands")
      eq(shell.service.brightnessAfterRead["eDP-1"], undefined, "no stale step left behind")
      eq(Object.keys(shell.service._stepRequester).length, 0, "no requester kept after its step")
      // Popup close: Wireless demand and the search go with it.
      panel(0).open()
      panel(0).popup.bodyItem.setTab("Wireless")
      eq(shell.service.wirelessWanted, true, "Wireless shown: wanted")
      panel(0).close()
      eq(shell.service.wirelessWanted, false, "popup closed: Wireless released")
      eq(shell.service.demanded, false, "popup closed: no demand")
      // A bar with Wireless open and a drag in progress goes away (its monitor unplugged).
      panel(2).open()
      var view = panel(2).popup.bodyItem
      view.setTab("Wireless")
      view.dragging = true
      eq(shell.service.wirelessWanted, true, "the unplugged bar wanted Wireless")
      eq(shell.service.arrangementDragActive, true, "and was dragging")
      shell.panelCount = 2
      lifeB.start()
    }
  }
  Timer {
    id: lifeB
    interval: 1500
    onTriggered: {
      eq(shell.service.members, 2, "two bars left")
      eq(shell.service.wirelessWanted, false, "a destroyed view releases Wireless")
      eq(shell.service.arrangementDragActive, false, "a destroyed view releases its drag")
      eq(shell.service.demanded, false, "a destroyed open popup releases its demand")
      eq(shell.service.scanning, false, "no scan or dependency check for a view that is gone")
      eq(shell.service.dependencyRetry.running, false, "no dependency retries")
      eq(shell.service.teardowns, 0, "other bars keep the service")
      shell.runsBefore = shell.service.statusRuns
      shell.service.refresh()
      lifeC.start()
    }
  }
  Timer {
    id: lifeC
    interval: 1000
    onTriggered: {
      eq(shell.service.statusRuns, shell.runsBefore + 1, "status runs again after the dragging view is gone")
      // Hot-plug: every bar rebuilt within the grace period keeps the service and a scan.
      shell.service.startWirelessScan()
      shell.panelCount = 0
      lifeD.start()
    }
  }
  Timer {
    id: lifeD
    interval: 800
    onTriggered: {
      shell.panelCount = 3
      lifeE.start()
    }
  }
  Timer {
    id: lifeE
    interval: 3500
    onTriggered: {
      eq(shell.service.members, 3, "bars rebuilt")
      eq(shell.service.teardowns, 0, "a rebuild within the grace period does not tear down")
      eq(shell.service.active, true, "service still active")
      eq(shell.service.scanRunning, true, "the scan survives the rebuild")
      eq(shell.leaders(), 1, "one leader after the rebuild")
      // ---- A running trial against every UI state ----
      shell.leaderPanel().openSettings()
      eq(shell.leaderPanel().editingSettings, true, "Settings open before the trial")
      // The trial worker's phase change, written to the helper's state file.
      shell.setPhase("testing")
      trialA.start()
    }
  }
  Timer {
    id: trialA
    interval: 1000
    onTriggered: {
      eq(shell.service.testing, true, "the trial arrives through the state file")
      eq(shell.leaderPanel().editingSettings, false, "a starting trial closes Settings")
      shell.leaderPanel().openSettings()
      eq(shell.leaderPanel().editingSettings, false, "Settings (IPC or key) cannot cover a running trial")
      eq(shell.leaderPanel().opened, true, "it shows the trial instead")
      eq(shell.openCount(), 1, "one popup shows the trial")
      var view = shell.leaderPanel().popup.bodyItem
      eq(JSON.stringify(view.stops), JSON.stringify(["revert", "keep"]), "only Revert and Keep take the cursor")
      view.setTab("Advanced")
      check(view.footerShown, "the trial footer shows on Advanced")
      view.setTab("Wireless")
      check(view.footerShown, "and on Wireless")
      shell.key(view, "s")
      eq(shell.leaderPanel().editingSettings, false, "s does nothing during a trial")
      shell.leaderPanel().close()
      trialB.start()
    }
  }
  Timer {
    id: trialB
    interval: 300
    onTriggered: {
      eq(shell.openCount(), 1, "closing the popup during a trial reopens it")
      var view = shell.leaderPanel().popup.bodyItem
      eq(view.cursorKey, "revert", "the reopened trial lands on Revert")
      shell.setPhase("idle")
      trialC.start()
    }
  }
  Timer {
    id: trialC
    interval: 1500
    onTriggered: {
      eq(shell.service.testing, false, "trial over")
      shell.leaderPanel().openSettings()
      eq(shell.leaderPanel().editingSettings, true, "Settings opens again once the change is done")
      shell.leaderPanel().close()
      wifiA.start()
    }
  }

  // ---- Wireless receivers cached in the service (2-minute TTL) ----
  // The fake FluxCast lists $FOAMY_CALLS.peers after $FOAMY_CALLS.scandelay s.
  property int scansBefore: 0
  function addresses() { return shell.service.wirelessPeers.map(function(p) { return p.address }).join(",") }
  Timer {
    id: wifiA
    interval: 300
    onTriggered: {
      eq(shell.service.scanning, false, "no scan left over before the cache checks")
      shell.service.wirelessPeers = []
      shell.service.wirelessScannedAt = 0
      shell.scansBefore = shell.service.wirelessScanRuns
      shell.sh("printf '[1] 7A:2D:91:40:0B:CE Living Room TV via NetworkManager\\n[2] 02:11:22:33:44:55 via NetworkManager\\n' > \"$FOAMY_CALLS.peers\"; printf 1.2 > \"$FOAMY_CALLS.scandelay\"")
      wifiB.start()
    }
  }
  Timer {
    id: wifiB
    interval: 500
    onTriggered: {
      panel(0).open()
      panel(0).popup.bodyItem.setTab("Wireless")
      wifiB2.start()
    }
  }
  // Process.running notifies once the process has started: check a moment later.
  Timer {
    id: wifiB2
    interval: 150
    onTriggered: {
      var view = panel(0).popup.bodyItem
      eq(shell.service.scanning, true, "showing Wireless with nothing cached starts a scan")
      eq(view.scanSpinning, true, "the Scan glyph spins during the first scan")
      eq(view.itemFor("scan").spinning, true, "FoamyAction spinning is set")
      eq(view.itemFor("scan").actionEnabled, false, "Scan is inert while it runs")
      eq(view.scanIndicatorShown, true, "an empty list shows the searching row")
      wifiC.start()
    }
  }
  Timer {
    id: wifiC
    interval: 700
    onTriggered: {
      eq(shell.service.scanRunning, true, "the scan runs")
      eq(shell.service.wirelessScanRuns, shell.scansBefore + 1, "one scan process")
      // Every bar shares the service: more requests while it runs start nothing.
      shell.service.checkWireless()
      shell.service.startWirelessScan()
      eq(shell.service.wirelessScanRuns, shell.scansBefore + 1, "still one scan for every bar")
      wifiD.start()
    }
  }
  Timer {
    id: wifiD
    interval: 1650
    onTriggered: {
      var view = panel(0).popup.bodyItem
      eq(shell.addresses(), "7A:2D:91:40:0B:CE,02:11:22:33:44:55", "the scan lists both receivers")
      eq(shell.service.wirelessScanState, "results", "results state")
      check(shell.service.wirelessScannedAt > 0, "the finished scan is timestamped")
      eq(view.scanSpinning, false, "the glyph stops with the scan")
      eq(view.scanIndicatorShown, false, "no searching row with results")
      view.place("peer:1")
      check(view.itemFor("peer:1") !== null, "both receivers are listed")
      panel(0).close()
      eq(shell.service.demanded, false, "popup closed")
      eq(shell.service.wirelessPeers.length, 2, "closing the popup keeps the receivers in the service")
      // Next scan: one receiver gone, one renamed, one new (listed first).
      shell.sh("printf '[1] 0A:0B:0C:0D:0E:0F Den via NetworkManager\\n[2] 02:11:22:33:44:55 Projector via NetworkManager\\n' > \"$FOAMY_CALLS.peers\"; printf 1.5 > \"$FOAMY_CALLS.scandelay\"")
      // Old enough for a refresh on reopen, well inside the TTL.
      shell.service.wirelessScannedAt -= 30000
      wifiE.start()
    }
  }
  Timer {
    id: wifiE
    interval: 1500
    onTriggered: {
      eq(shell.service.wirelessScanRuns, shell.scansBefore + 1, "nothing scans while every popup is closed")
      eq(shell.service.scanning, false, "no scan or check while closed")
      // Reopen on another bar: the cached list at once, refreshed silently.
      panel(1).open()
      var view = panel(1).popup.bodyItem
      view.setTab("Wireless")
      eq(shell.addresses(), "7A:2D:91:40:0B:CE,02:11:22:33:44:55", "the reopened popup shows the cached list at once")
      view.place("peer:1")
      check(view.itemFor("peer:1") !== null, "cached receivers are listed")
      wifiE2.start()
    }
  }
  Timer {
    id: wifiE2
    interval: 150
    onTriggered: {
      var view = panel(1).popup.bodyItem
      eq(shell.service.scanning, true, "and refreshes it")
      eq(shell.service.wirelessRefreshing, true, "silently")
      eq(view.scanSpinning, true, "only the Scan glyph spins")
      eq(view.scanIndicatorShown, false, "no searching row over a cached list")
      check(view.stops.indexOf("peer:1") > 0, "cached receivers keep cursor stops during the refresh")
      wifiF.start()
    }
  }
  Timer {
    id: wifiF
    interval: 550
    onTriggered: {
      eq(shell.service.wirelessScanRuns, shell.scansBefore + 2, "one refresh")
      eq(shell.addresses(), "7A:2D:91:40:0B:CE,02:11:22:33:44:55", "the list holds still while it refreshes")
      wifiG.start()
    }
  }
  Timer {
    id: wifiG
    interval: 1800
    onTriggered: {
      var view = panel(1).popup.bodyItem
      eq(shell.addresses(), "02:11:22:33:44:55,0A:0B:0C:0D:0E:0F", "merged: kept order, gone dropped, new appended")
      eq(shell.service.wirelessPeers[0].name, "Projector", "fresh details replace cached ones")
      eq(view.scanSpinning, false, "refresh done")
      // A reopen right after a scan does not scan again.
      panel(1).close()
      panel(1).open()
      eq(shell.service.scanning, false, "no rescan right after a finished scan")
      eq(shell.service.wirelessPeers.length, 2, "the list is still there")
      // Past the TTL the cached list is discarded on open: a normal scan.
      panel(1).close()
      shell.service.wirelessScannedAt = Date.now() - 121000
      panel(1).open()
      eq(shell.service.wirelessPeers.length, 0, "a list older than the TTL is discarded on open")
      eq(shell.service.wirelessScannedAt, 0, "and its timestamp with it")
      wifiG2.start()
    }
  }
  Timer {
    id: wifiG2
    interval: 150
    onTriggered: {
      eq(panel(1).popup.bodyItem.scanIndicatorShown, true, "the searching row shows for the new scan")
      wifiH.start()
    }
  }
  Timer {
    id: wifiH
    interval: 2350
    onTriggered: {
      var view = panel(1).popup.bodyItem
      eq(shell.service.wirelessPeers.length, 2, "the new scan lists the receivers")
      // Picking a receiver during a refresh stops the scan, then casts.
      shell.sh("printf 5 > \"$FOAMY_CALLS.scandelay\"")
      shell.service.wirelessScannedAt -= 30000
      wifiI.start()
    }
  }
  Timer {
    id: wifiI
    interval: 300
    onTriggered: {
      var view = panel(1).popup.bodyItem
      view.scanOrStop()
      wifiJ.start()
    }
  }
  Timer {
    id: wifiJ
    interval: 600
    onTriggered: {
      var view = panel(1).popup.bodyItem
      eq(shell.service.scanRunning, true, "a refresh runs")
      eq(shell.service.wirelessPeers.length, 2, "the Scan button keeps the list too")
      view.connectPeer(shell.service.wirelessPeers[0])
      check(shell.service.pendingCast !== null, "the pick waits for the scan to stop")
      wifiK.start()
    }
  }
  Timer {
    id: wifiK
    interval: 1200
    onTriggered: {
      eq(shell.service.scanRunning, false, "the refresh was stopped")
      eq(shell.service.pendingCast, null, "the pick was taken")
      check(shell.service.castPhase !== "idle", "the cast started after the scan: " + shell.service.castPhase)
      eq(shell.service.wirelessPeers.length, 2, "a stopped refresh keeps the list")
      shell.service.stopCast()
      panel(1).close()
      shell.sh("rm -f \"$FOAMY_CALLS.peers\" \"$FOAMY_CALLS.scandelay\"")
      shell.panelCount = 0
      stepEight.start()
    }
  }

  Timer {
    id: stepEight
    interval: 4500
    onTriggered: {
      eq(shell.service.members, 0, "every panel gone")
      eq(shell.service.teardowns, 1, "teardown after the last panel left")
      eq(shell.service.active, false, "service idle")
      eq(shell.service.scanRunning, false, "scan stopped")
      eq(shell.service.commands.length, 0, "no queued commands after teardown")
      eq(shell.service.statusPending, false, "no pending refresh after teardown")
      shell.finish()
    }
  }

  function sh(script) {
    var p = Qt.createQmlObject('import Quickshell.Io; Process {}', shell)
    p.command = ["sh", "-c", script]
    p.running = true
  }

  property int holdMs: Number(Quickshell.env("FOAMY_HOLD_MS") || 0)
  function finish() {
    console.log("FOAMY RESULT " + host + "/" + lang + " " + checks + " checks, " + failures + " failures")
    finishTimer.start()
  }
  Timer {
    id: finishTimer
    interval: shell.holdMs
    onTriggered: { console.log("FOAMY DONE"); Qt.quit() }
  }
}
