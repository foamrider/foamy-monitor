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
//
// Each step waits for the state it checks (FoamyWait.waitFor), so a loaded
// machine only makes the run slower. wait.after() is kept where the time is
// the point: nothing may happen within it (a debounce, a closed popup).
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

  FoamyWait { id: wait }
  // Waits for condition() (at most timeoutMs, default 15 s), records whether
  // it held as a check named `label`, then runs next().
  function until(condition, label, next, timeoutMs) {
    wait.waitFor(condition, timeoutMs || 15000, function(ok) {
      check(ok, "waited for: " + label)
      next()
    })
  }
  // No helper command running or about to run.
  function displayIdle() {
    return !service.commandProc.running && !service.statusDebounce.running && service.commands.length === 0 && !service.statusPending
  }
  // No brightness job running or waiting.
  function brightnessIdle() {
    return !service.brightnessProc.running && !service.brightnessDebounce.running && service.brightnessReads.length === 0
      && Object.keys(service.brightnessWrites).length === 0
  }

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

  Component.onCompleted: until(function() {
    return leaders() === 1 && service.members === 3 && service.statusRuns >= 1 && service.liveMonitors.length === 3
      && service.statePath !== "" && displayIdle()
  }, "the startup status", stepOne)

  // The trial worker's phase change, written to the helper's state file. A
  // "testing" phase gets a stand-in worker (a process whose command line
  // holds `worker --token runtime-trial`, as the helper checks); "dead"
  // writes a testing phase whose worker is gone; "idle" ends the stand-in.
  function setPhase(phase, then) {
    sh("python3 - '" + service.statePath + "' " + phase + " <<'PY'\n"
      + "import json, os, signal, subprocess, sys, time\n"
      + "p, phase = sys.argv[1], sys.argv[2]\n"
      + "s = json.load(open(p))\n"
      + "if s.get('workerPid'):\n"
      + "    try: os.kill(s['workerPid'], signal.SIGKILL)\n"
      + "    except OSError: pass\n"
      + "s.update(phase='testing' if phase == 'dead' else phase, deadline=time.time() + 15 if phase != 'idle' else 0, token='runtime-trial', workerPid=0)\n"
      + "if phase == 'dead':\n"
      + "    s['snapshot'] = s.get('base', [])\n"
      + "if phase == 'testing':\n"
      + "    s['workerPid'] = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)', 'worker', '--token', 'runtime-trial'], start_new_session=True).pid\n"
      + "s['revision'] = s.get('revision', 0) + 1\n"
      + "json.dump(s, open(p, 'w'))\n"
      + "PY", then)
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

  function stepOne() {
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
    external.command = shell.service.helper(["patch"])
    external.running = true
    until(function() { return shell.service.transaction.draft[1].x === 4000 && displayIdle() }, "the draft written elsewhere", stepTwo)
  }

  function stepTwo() {
    eq(shell.service.transaction.draft[1].x, 4000, "a draft written elsewhere arrives through the file watch")
    check(shell.service.statusRuns > shell.runsBefore, "the file watch ran status with every popup closed")
    eq(shell.service.changeCount, 1, "one unsaved change")
    // The helper replaces the file atomically; the watch must survive that.
    external.payload = JSON.stringify({ id: shell.service.transaction.draft[1].id, changes: { x: 4100 } })
    external.running = true
    until(function() { return shell.service.transaction.draft[1].x === 4100 && displayIdle() }, "the second write", stepTwoB)
  }

  function stepTwoB() {
    eq(shell.service.transaction.draft[1].x, 4100, "a second write arrives too (watch survives the atomic replace)")
    shell.runsBefore = shell.service.statusRuns
    shell.service.hyprlandEvents.onRawEvent({ name: "focusedmon" })
    shell.service.hyprlandEvents.onRawEvent({ name: "workspacev2" })
    // Four times the 150 ms debounce: a status these events started would show.
    wait.after(600, stepThree)
  }

  function stepThree() {
    eq(shell.service.statusRuns, shell.runsBefore, "focus and workspace events do not run status")
    shell.service.hyprlandEvents.onRawEvent({ name: "monitoraddedv2" })
    shell.service.hyprlandEvents.onRawEvent({ name: "configreloaded" })
    until(function() { return shell.service.statusRuns > shell.runsBefore && displayIdle() }, "the output events' status", stepFour)
  }

  function stepFour() {
    eq(shell.service.statusRuns, shell.runsBefore + 1, "output events run one debounced status")
    // An output change while a status run is in flight (it already read the
    // outputs): the event's refresh must run after it, not be dropped.
    shell.runsBefore = shell.service.statusRuns
    shell.sh("printf 2 > \"$FOAMY_CALLS.hyprdelay\"", inflightA)
  }

  function inflightA() {
    shell.service.refresh()
    eq(shell.service.commandProc.running, true, "a slow status run is in flight")
    // The fake hyprctl reads the outputs as it starts, then answers 2 s later.
    wait.after(300, inflightB)
  }
  function inflightB() {
    shell.sh("python3 - <<'PY'\nimport json, os\np = os.path.join(os.environ['FOAMY_FAKEBIN'], 'monitors.json')\nrows = json.load(open(p))\nrows[2]['y'] = 100\njson.dump(rows, open(p, 'w'))\nPY", inflightC)
  }
  function inflightC() {
    eq(shell.service.commandProc.running, true, "still in flight when the event arrives")
    shell.service.hyprlandEvents.onRawEvent({ name: "monitoraddedv2" })
    until(function() { return shell.service.statusRuns >= shell.runsBefore + 2 && displayIdle() }, "the follow-up run", inflightD)
  }
  function inflightD() {
    eq(shell.service.liveMonitors[2].y, 100, "the change made during the run arrives")
    eq(shell.service.statusRuns, shell.runsBefore + 2, "exactly one follow-up run")
    eq(shell.service.statusPending, false, "nothing left pending")
    // Every output gone for a moment (a KVM switch, undocking): that status
    // run fails, and the next good one must clear its error.
    shell.sh("rm -f \"$FOAMY_CALLS.hyprdelay\"; cd \"$FOAMY_FAKEBIN\" && cp monitors.json monitors.json.kept && printf '[]' > monitors.json", function() {
      shell.afterStatus(statusErrorA)
    })
  }
  function statusErrorA() {
    eq(shell.service.error, "No connected displays", "a failed status run shows its error")
    shell.sh("cd \"$FOAMY_FAKEBIN\" && mv monitors.json.kept monitors.json", function() { shell.afterStatus(statusErrorB) })
  }
  function statusErrorB() {
    eq(shell.service.error, "", "the next good status run clears it")
    eq(shell.service.liveMonitors.length, 3, "the displays are back")
    panel(0).open()
    until(function() {
      var view = panel(0).popup.bodyItem
      return view && view.brightnessAvailable && displayIdle() && brightnessIdle()
    }, "the popup's brightness read", stepFive)
  }
  // Runs one status and calls next once it has landed.
  function afterStatus(next) {
    var before = service.statusRuns
    service.refresh()
    until(function() { return service.statusRuns > before && displayIdle() }, "a status run", function() {
      // One more turn after the run ends, so its stdout has been handled too.
      wait.after(100, next)
    })
  }

  function stepFive() {
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
    // No settings: no Settings button, no Settings stop, `s` does nothing.
    eq(view.band.settingsButton.visible, false, "no Settings button")
    eq(view.stops.indexOf("settings"), -1, "no Settings stop")
    shell.key(view, "s")
    eq(view.blocked, false, "s opens nothing")
    view.closeRequested()
    eq(first.opened, false, "Esc closes")
    // IPC `open` as the first action builds the lazy body.
    panel(1).open()
    // Brightness from three bars at once: one DDC job at a time.
    for (var i = 0; i < 3; i++) shell.service.changeBrightness(shell.service.liveMonitors[i].name, { delta: 5 }, panel(i))
    eq(first.brightnessIpc("abc"), "error: expected a percentage such as 40, +5 or -5", "IPC rejects junk")
    until(function() {
      var moved = shell.service.transaction.draft.find(function(m) { return m.name === "DP-1" })
      return moved.x === shell.runsBefore + 30 && displayIdle() && brightnessIdle() && shell.service.brightness["DP-2"]
        && shell.service.brightness["DP-2"].percent === 55
    }, "the nudges and the wheel steps", stepSix)
  }

  function stepSix() {
    var draft = shell.service.transaction.draft
    eq(draft.find(function(m) { return m.name === "DP-1" }).x, shell.runsBefore + 30, "three quick arrows nudge the display by 30 px")
    eq(shell.service.brightness["DP-2"].percent, 55, "a wheel step before the first read lands after it")
    check(mockBar.summoned.length >= 1 && mockBar.summoned[0].id === "omarchy.osd" && mockBar.summoned[0].payload.icon === "brightness",
      "the wheel shows the Omarchy OSD: " + JSON.stringify(mockBar.summoned))
    eq(shell.service.brightnessProc.running, false, "brightness queue drained")
    var second = panel(1).popup.bodyItem
    check(second !== null, "the body builds on a fresh panel")
    panel(1).close()
    // The level changed elsewhere (laptop keys, the monitor's buttons) while
    // every popup was closed: a wheel step after the burst re-reads first.
    var aged = Object.assign({}, shell.service.brightness)
    aged["DP-2"] = { available: true, percent: 55, at: Date.now() - 10000 }
    shell.service.brightness = aged
    shell.sh("printf 80 > \"$FOAMY_CALLS.brightness.DP-2\"", stepSixB)
  }

  function stepSixB() {
    eq(shell.service.changeBrightness("DP-2", { delta: 5 }, panel(2)), 0, "a stale level is read again before stepping")
    until(function() { return brightnessIdle() && shell.service.brightness["DP-2"].percent === 85 }, "the re-read step", stepSixC)
  }

  function stepSixC() {
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
    until(function() { return brightnessIdle() && Object.keys(shell.service.brightnessAfterRead).length === 0 }, "the queued levels", hangA)
  }

  // ---- A hung DDC job (fake: $FOAMY_CALLS.ddchang, ignores SIGTERM) ----
  // It ends at the deadline (SIGTERM, then SIGKILL 2 s later) and the
  // brightness change queued behind it still lands.
  function hangA() {
    eq(shell.service.brightness["DP-1"].percent, 45, "40 then +5 lands on 45, not the hardware level + 5")
    eq(shell.service.brightness["eDP-1"].percent, 40, "the explicit level stays after the read lands")
    eq(shell.service.brightnessAfterRead["eDP-1"], undefined, "no stale step left behind")
    eq(Object.keys(shell.service._stepRequester).length, 0, "no requester kept after its step")
    eq(shell.service.brightnessProc.running, false, "brightness queue idle before the hang")
    shell.service.brightnessTimeoutSeconds = 1
    shell.sh("touch \"$FOAMY_CALLS.ddchang\"", hangB)
  }
  function hangB() {
    var unknown = Object.assign({}, shell.service.brightness)
    delete unknown["DP-1"]
    shell.service.brightness = unknown
    eq(shell.service.changeBrightness("DP-1", { delta: 5 }, null), 0, "a step on an unread display waits for its read")
    // The fake ignores SIGTERM, so the job lives until the SIGKILL at 3 s.
    wait.after(600, hangC)
  }
  function hangC() {
    eq(shell.service.brightnessProc.running, true, "the read hangs")
    eq(shell.service.changeBrightness("eDP-1", { value: 30 }, null), 30, "a later level is accepted")
    shell.sh("rm -f \"$FOAMY_CALLS.ddchang\"", function() {
      until(function() { return brightnessIdle() && shell.service.brightness["DP-1"] !== undefined }, "the hung read's deadline", hangD)
    })
  }
  function hangD() {
    eq(shell.service.brightnessProc.running, false, "the hung read ended at its deadline")
    eq(shell.service.brightness["DP-1"].available, false, "a timed-out read is a failed read")
    eq(Object.keys(shell.service.brightnessAfterRead).length, 0, "no step left waiting on the hung read")
    eq(Object.keys(shell.service.brightnessWrites).length, 0, "the level queued behind it was written")
    shell.service.brightnessTimeoutSeconds = 20
    shell.service.readBrightness("eDP-1")
    until(brightnessIdle, "the read after the hang", lifeA)
  }

  // ---- Per-view demand: popup close, a bar removed (unplug), hot-plug grace ----
  function lifeA() {
    eq(shell.service.brightness["eDP-1"].available === true && shell.service.brightness["eDP-1"].percent, 30, "the written level reads back after the hang")
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
    until(function() { return shell.service.members === 2 && !shell.service.scanning && displayIdle() }, "the unplugged bar", lifeB)
  }
  function lifeB() {
    eq(shell.service.members, 2, "two bars left")
    eq(shell.service.wirelessWanted, false, "a destroyed view releases Wireless")
    eq(shell.service.arrangementDragActive, false, "a destroyed view releases its drag")
    eq(shell.service.demanded, false, "a destroyed open popup releases its demand")
    eq(shell.service.scanning, false, "no scan or dependency check for a view that is gone")
    eq(shell.service.dependencyRetry.running, false, "no dependency retries")
    eq(shell.service.teardowns, 0, "other bars keep the service")
    shell.runsBefore = shell.service.statusRuns
    shell.service.refresh()
    until(function() { return shell.service.statusRuns > shell.runsBefore && displayIdle() }, "the status after the drag", lifeC)
  }
  function lifeC() {
    eq(shell.service.statusRuns, shell.runsBefore + 1, "status runs again after the dragging view is gone")
    // Hot-plug: every bar rebuilt within the grace period keeps the service and a scan.
    shell.service.startWirelessScan()
    shell.panelCount = 0
    wait.after(800, lifeD)
  }
  function lifeD() {
    shell.panelCount = 3
    until(function() { return shell.service.members === 3 && shell.leaders() === 1 }, "the rebuilt bars", lifeE)
  }
  function lifeE() {
    eq(shell.service.members, 3, "bars rebuilt")
    eq(shell.service.releaseTimer.running, false, "the release grace stopped with the rebuild")
    eq(shell.service.teardowns, 0, "a rebuild within the grace period does not tear down")
    eq(shell.service.active, true, "service still active")
    eq(shell.service.scanRunning, true, "the scan survives the rebuild")
    eq(shell.leaders(), 1, "one leader after the rebuild")
    // ---- A running trial against every UI state ----
    shell.leaderPanel().open()
    // The trial worker's phase change, written to the helper's state file.
    shell.setPhase("testing", function() {
      until(function() { return shell.service.testing && shell.leaderPanel().opened && displayIdle() }, "the trial", trialA)
    })
  }
  function trialA() {
    eq(shell.service.testing, true, "the trial arrives through the state file")
    eq(shell.leaderPanel().opened, true, "the popup shows the trial")
    eq(shell.openCount(), 1, "one popup shows the trial")
    var view = shell.leaderPanel().popup.bodyItem
    eq(JSON.stringify(view.stops), JSON.stringify(["revert", "keep"]), "only Revert and Keep take the cursor")
    view.setTab("Advanced")
    check(view.footerShown, "the trial footer shows on Advanced")
    view.setTab("Wireless")
    check(view.footerShown, "and on Wireless")
    shell.leaderPanel().close()
    until(function() { return shell.openCount() === 1 }, "the trial popup to reopen", trialB, 5000)
  }
  function trialB() {
    eq(shell.openCount(), 1, "closing the popup during a trial reopens it")
    var view = shell.leaderPanel().popup.bodyItem
    eq(view.cursorKey, "revert", "the reopened trial lands on Revert")
    shell.setPhase("idle", function() {
      until(function() { return !shell.service.testing && displayIdle() }, "the trial's end", trialC)
    })
  }
  function trialC() {
    eq(shell.service.testing, false, "trial over")
    // A trial whose worker is gone (killed, crashed): the busy poll's next
    // status reverts it and says so, in the popup's language.
    shell.setPhase("dead", function() {
      until(function() { return shell.service.transaction.error !== "" && !shell.service.busy && displayIdle() }, "the dead trial's recovery", trialD)
    })
  }
  function trialD() {
    eq(shell.service.transaction.phase, "idle", "a dead trial goes idle")
    var view = shell.leaderPanel().popup.bodyItem
    eq(view.tr(view.actionError), shell.lang === "no" ? "Skjermtesten stoppet uventet. De forrige innstillingene ble gjenopprettet."
      : "The display test stopped unexpectedly. The previous settings were restored.", "the recovery says so")
    shell.leaderPanel().close()
    until(function() { return !shell.service.scanning }, "the scan to stop with the last popup", wifiA)
  }

  // ---- Wireless receivers cached in the service (2-minute TTL) ----
  // The fake FluxCast lists $FOAMY_CALLS.peers after $FOAMY_CALLS.scandelay s.
  property int scansBefore: 0
  function addresses() { return shell.service.wirelessPeers.map(function(p) { return p.address }).join(",") }
  function wifiA() {
    eq(shell.service.scanning, false, "no scan left over before the cache checks")
    shell.service.wirelessPeers = []
    shell.service.wirelessScannedAt = 0
    shell.scansBefore = shell.service.wirelessScanRuns
    shell.sh("printf '[1] 7A:2D:91:40:0B:CE Living Room TV via NetworkManager\\n[2] 02:11:22:33:44:55 via NetworkManager\\n' > \"$FOAMY_CALLS.peers\"; printf 1.2 > \"$FOAMY_CALLS.scandelay\"", wifiB)
  }
  function wifiB() {
    panel(0).open()
    panel(0).popup.bodyItem.setTab("Wireless")
    // Process.running notifies once the process has started.
    until(function() { return panel(0).popup.bodyItem.scanSpinning }, "the first scan", wifiB2)
  }
  function wifiB2() {
    var view = panel(0).popup.bodyItem
    eq(shell.service.scanning, true, "showing Wireless with nothing cached starts a scan")
    eq(view.scanSpinning, true, "the Scan glyph spins during the first scan")
    eq(view.itemFor("scan").spinning, true, "FoamyAction spinning is set")
    eq(view.itemFor("scan").actionEnabled, false, "Scan is inert while it runs")
    eq(view.scanIndicatorShown, true, "an empty list shows the searching row")
    until(function() { return shell.service.scanRunning }, "the scan process", wifiC)
  }
  function wifiC() {
    eq(shell.service.scanRunning, true, "the scan runs")
    eq(shell.service.wirelessScanRuns, shell.scansBefore + 1, "one scan process")
    // Every bar shares the service: more requests while it runs start nothing.
    shell.service.checkWireless()
    shell.service.startWirelessScan()
    eq(shell.service.wirelessScanRuns, shell.scansBefore + 1, "still one scan for every bar")
    until(function() { return !shell.service.scanning && shell.service.wirelessScanState === "results" }, "the scan's results", wifiD)
  }
  function wifiD() {
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
    shell.sh("printf '[1] 0A:0B:0C:0D:0E:0F Den via NetworkManager\\n[2] 02:11:22:33:44:55 Projector via NetworkManager\\n' > \"$FOAMY_CALLS.peers\"; printf 1.5 > \"$FOAMY_CALLS.scandelay\"", function() {
      // Old enough for a refresh on reopen, well inside the TTL.
      shell.service.wirelessScannedAt -= 30000
      wait.after(1500, wifiE)
    })
  }
  function wifiE() {
    eq(shell.service.wirelessScanRuns, shell.scansBefore + 1, "nothing scans while every popup is closed")
    eq(shell.service.scanning, false, "no scan or check while closed")
    // Reopen on another bar: the cached list at once, refreshed silently.
    panel(1).open()
    var view = panel(1).popup.bodyItem
    view.setTab("Wireless")
    eq(shell.addresses(), "7A:2D:91:40:0B:CE,02:11:22:33:44:55", "the reopened popup shows the cached list at once")
    view.place("peer:1")
    check(view.itemFor("peer:1") !== null, "cached receivers are listed")
    until(function() { return panel(1).popup.bodyItem.scanSpinning }, "the refresh", wifiE2)
  }
  function wifiE2() {
    var view = panel(1).popup.bodyItem
    eq(shell.service.scanning, true, "and refreshes it")
    eq(shell.service.wirelessRefreshing, true, "silently")
    eq(view.scanSpinning, true, "only the Scan glyph spins")
    eq(view.scanIndicatorShown, false, "no searching row over a cached list")
    check(view.stops.indexOf("peer:1") > 0, "cached receivers keep cursor stops during the refresh")
    until(function() { return shell.service.scanRunning }, "the refresh's scan process", wifiF)
  }
  function wifiF() {
    eq(shell.service.wirelessScanRuns, shell.scansBefore + 2, "one refresh")
    eq(shell.addresses(), "7A:2D:91:40:0B:CE,02:11:22:33:44:55", "the list holds still while it refreshes")
    until(function() { return !shell.service.scanning && shell.service.wirelessScanState === "results" }, "the refresh's results", wifiG)
  }
  function wifiG() {
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
    until(function() { return panel(1).popup.bodyItem.scanIndicatorShown }, "the new scan", wifiG2)
  }
  function wifiG2() {
    eq(panel(1).popup.bodyItem.scanIndicatorShown, true, "the searching row shows for the new scan")
    until(function() { return !shell.service.scanning && shell.service.wirelessPeers.length === 2 }, "the new scan's results", wifiH)
  }
  function wifiH() {
    eq(shell.service.wirelessPeers.length, 2, "the new scan lists the receivers")
    // Picking a receiver during a refresh stops the scan, then casts.
    shell.sh("printf 5 > \"$FOAMY_CALLS.scandelay\"", function() {
      shell.service.wirelessScannedAt -= 30000
      panel(1).popup.bodyItem.scanOrStop()
      until(function() { return shell.service.scanRunning }, "the Scan button's refresh", wifiJ)
    })
  }
  function wifiJ() {
    var view = panel(1).popup.bodyItem
    eq(shell.service.scanRunning, true, "a refresh runs")
    eq(shell.service.wirelessPeers.length, 2, "the Scan button keeps the list too")
    view.connectPeer(shell.service.wirelessPeers[0])
    check(shell.service.pendingCast !== null, "the pick waits for the scan to stop")
    until(function() { return !shell.service.scanRunning && shell.service.pendingCast === null && shell.service.castRunning }, "the cast after the scan", wifiK)
  }
  function wifiK() {
    eq(shell.service.scanRunning, false, "the refresh was stopped")
    eq(shell.service.pendingCast, null, "the pick was taken")
    check(shell.service.castPhase !== "idle", "the cast started after the scan: " + shell.service.castPhase)
    eq(shell.service.wirelessPeers.length, 2, "a stopped refresh keeps the list")
    shell.service.stopCast()
    panel(1).close()
    shell.sh("rm -f \"$FOAMY_CALLS.peers\" \"$FOAMY_CALLS.scandelay\"", function() {
      shell.panelCount = 0
      until(function() { return shell.service.teardowns === 1 && !shell.service.scanRunning && !shell.service.castRunning }, "the teardown", stepEight)
    })
  }

  function stepEight() {
    eq(shell.service.members, 0, "every panel gone")
    eq(shell.service.teardowns, 1, "teardown after the last panel left")
    eq(shell.service.active, false, "service idle")
    eq(shell.service.scanRunning, false, "scan stopped")
    eq(shell.service.commands.length, 0, "no queued commands after teardown")
    eq(shell.service.statusPending, false, "no pending refresh after teardown")
    shell.finish()
  }

  // Runs a shell script; then() (optional) once it has exited.
  function sh(script, then) {
    var p = Qt.createQmlObject('import Quickshell.Io; Process {}', shell)
    if (then) p.exited.connect(function() { then() })
    p.command = ["sh", "-c", script]
    p.running = true
  }

  property int holdMs: Number(Quickshell.env("FOAMY_HOLD_MS") || 0)
  function finish() {
    console.log("FOAMY RESULT " + host + "/" + lang + " " + checks + " checks, " + failures + " failures")
    wait.after(Math.max(1, shell.holdMs), function() { console.log("FOAMY DONE"); Qt.quit() })
  }
}
