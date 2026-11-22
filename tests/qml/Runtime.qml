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
// the single keyboard cursor, serialised brightness, a running trial (Revert
// and Keep, Esc reverts), refused dropdown picks, the wireless cache, the
// cast, RTL, and the teardown that stops a running cast when the last panel
// goes.
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
    if (!ok) {
      failures++
      console.log("FOAMY FAIL " + host + "/" + lang + " " + label)
    }
  }
  function eq(actual, expected, label) {
    check(actual === expected, label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
  }
  FoamyCursor {
    id: keys
  }
  function key(view, text) {
    keys.emitTextKey(view, text)
  }
  function panel(i) {
    return panels.itemAt(i)
  }
  readonly property var service: Monitor.MonitorService

  FoamyWait {
    id: wait
  }
  // Waits for condition() (at most timeoutMs, default 15 s), records whether
  // it held as a check named `label`, then runs next().
  function until(condition, label, next, timeoutMs) {
    wait.waitFor(condition, timeoutMs || 15000, function (ok) {
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
    return !service.brightnessProc.running && !service.brightnessDebounce.running && service.brightnessReads.length === 0 && Object.keys(service.brightnessWrites).length === 0
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
        Monitor.Panel {
          bar: mockBar
        }
      }
    }
  }

  MockBar {
    id: mockBar
    moduleName: "foamy.monitor"
    property var summoned: []
    shell: QtObject {
      function updateEntryInline(id, settings) {
        return true
      }
      function summon(id, payload) {
        mockBar.summoned = mockBar.summoned.concat([
          {
            id: id,
            payload: JSON.parse(payload)
          }
        ])
        return true
      }
    }
  }

  // The fakes' calls log ($FOAMY_CALLS). text() right after reload() can
  // still return what the previous reload read, so the steps poll it in a
  // wait and never take one read as the file as it is now.
  FileView {
    id: callsLog
    path: Quickshell.env("FOAMY_CALLS")
    blockLoading: true
    printErrors: false
  }
  // The calls logged after the last `marker` line (see mark()).
  function linesAfter(marker) {
    callsLog.reload()
    var lines = String(callsLog.text()).split("\n")
    var at = lines.lastIndexOf(marker)
    return at < 0 ? [] : lines.slice(at + 1)
  }
  function loggedAfter(marker, prefix) {
    return linesAfter(marker).some(function (line) {
      return line.indexOf(prefix) === 0
    })
  }
  // Appends `marker` to the calls log, then runs next().
  function mark(marker, next) {
    sh("printf '%s\\n' '" + marker + "' >> \"$FOAMY_CALLS\"", next)
  }

  // Another bar instance or the trial worker writing the shared state file.
  Process {
    id: external
    property string payload: ""
    stdinEnabled: true
    onStarted: write(payload + "\n")
  }

  Component.onCompleted: until(function () {
    return leaders() === 1 && service.members === 3 && service.statusRuns >= 1 && service.liveMonitors.length === 3 && service.statePath !== "" && displayIdle()
  }, "the startup status", stepOne)

  // The trial worker's phase change, written to the helper's state file
  // under its state.lock and replaced atomically, as the helper does. A
  // "testing" phase gets a stand-in worker (a process whose command line
  // holds `worker --token runtime-trial`, as the helper checks); "dead"
  // writes a testing phase whose worker is gone; "idle" ends the stand-in.
  function setPhase(phase, then) {
    sh("python3 - '" + service.statePath + "' " + phase + " <<'PY'\n" + "import fcntl, json, os, signal, subprocess, sys, time\n" + "p, phase = sys.argv[1], sys.argv[2]\n" + "lock = open(os.path.join(os.path.dirname(p), 'state.lock'), 'a')\n" + "fcntl.flock(lock, fcntl.LOCK_EX)\n" + "s = json.load(open(p))\n" + "if s.get('workerPid'):\n" + "    try: os.kill(s['workerPid'], signal.SIGKILL)\n" + "    except OSError: pass\n" + "s.update(phase='testing' if phase == 'dead' else phase, deadline=time.time() + 15 if phase != 'idle' else 0, token='runtime-trial', workerPid=0)\n" + "if phase == 'dead':\n" + "    s['snapshot'] = s.get('base', [])\n" + "if phase == 'testing':\n" + "    s['workerPid'] = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)', 'worker', '--token', 'runtime-trial'], start_new_session=True).pid\n" + "s['revision'] = s.get('revision', 0) + 1\n" + "with open(p + '.tmp', 'w') as out:\n" + "    json.dump(s, out)\n" + "os.replace(p + '.tmp', p)\n" + "PY", then)
  }
  function leaderPanel() {
    for (var i = 0; i < panelCount; i++)
      if (panel(i).member.isLeader)
        return panel(i)
    return null
  }
  function openCount() {
    var count = 0
    for (var i = 0; i < panelCount; i++)
      if (panel(i).opened)
        count++
    return count
  }
  function leaders() {
    var count = 0
    for (var i = 0; i < panelCount; i++)
      if (panel(i).member.isLeader)
        count++
    return count
  }

  function stepOne() {
    eq(shell.leaders(), 1, "one leader across three bar instances")
    eq(shell.service.members, 3, "three members")
    // The harness has one screen; the glyph is an escaped private-use code point.
    eq(panel(0).barGlyph.codePointAt(0), 0xf0379, "one screen, no cast: the single-display glyph")
    eq(shell.service.statusRuns, 1, "one startup status for every instance")
    eq(shell.service.liveMonitors.length, 3, "three displays read")
    eq(panel(0).popup.bodyItem, null, "popup body is lazy")
    eq(shell.service.demanded, false, "no demand while closed")
    eq(Object.keys(shell.service.brightness).length, 0, "no brightness probe at startup")
    console.log("FOAMY READY")
    shell.runsBefore = shell.service.statusRuns
    var draft = shell.service.transaction.draft
    external.payload = JSON.stringify({
      id: draft[1].id,
      changes: {
        x: 4000
      }
    })
    external.command = shell.service.helper(["patch"])
    external.running = true
    until(function () {
      return shell.service.transaction.draft[1].x === 4000 && displayIdle()
    }, "the draft written elsewhere", stepTwo)
  }

  function stepTwo() {
    eq(shell.service.transaction.draft[1].x, 4000, "a draft written elsewhere arrives through the file watch")
    check(shell.service.statusRuns > shell.runsBefore, "the file watch ran status with every popup closed")
    eq(shell.service.changeCount, 1, "one unsaved change")
    // The helper replaces the file atomically; the watch must survive that.
    external.payload = JSON.stringify({
      id: shell.service.transaction.draft[1].id,
      changes: {
        x: 4100
      }
    })
    external.running = true
    until(function () {
      return shell.service.transaction.draft[1].x === 4100 && displayIdle()
    }, "the second write", stepTwoB)
  }

  function stepTwoB() {
    eq(shell.service.transaction.draft[1].x, 4100, "a second write arrives too (watch survives the atomic replace)")
    shell.runsBefore = shell.service.statusRuns
    shell.service.hyprlandEvents.onRawEvent({
      name: "focusedmon"
    })
    shell.service.hyprlandEvents.onRawEvent({
      name: "workspacev2"
    })
    // Four times the 150 ms debounce: a status these events started would show.
    wait.after(600, stepThree)
  }

  function stepThree() {
    eq(shell.service.statusRuns, shell.runsBefore, "focus and workspace events do not run status")
    shell.service.hyprlandEvents.onRawEvent({
      name: "monitoraddedv2"
    })
    shell.service.hyprlandEvents.onRawEvent({
      name: "configreloaded"
    })
    until(function () {
      return shell.service.statusRuns > shell.runsBefore && displayIdle()
    }, "the output events' status", stepFour)
  }

  function stepFour() {
    eq(shell.service.statusRuns, shell.runsBefore + 1, "output events run one debounced status")
    // An output change while a status run is in flight (it already read the
    // outputs): the event's refresh must run after it, not be dropped.
    shell.runsBefore = shell.service.statusRuns
    shell.sh("printf 2 > \"$FOAMY_CALLS.hyprdelay\"", inflightA)
  }

  function inflightA() {
    shell.mark("inflight-start", function () {
      shell.service.refresh()
      eq(shell.service.commandProc.running, true, "a slow status run is in flight")
      // The fake hyprctl logs hyprctl-read once it has read the outputs, then
      // answers 2 s later: after that line, a change is too late for it.
      until(function () {
        return shell.loggedAfter("inflight-start", "hyprctl-read")
      }, "the slow run read the outputs", inflightB)
    })
  }
  function inflightB() {
    shell.sh("python3 - <<'PY'\nimport json, os\np = os.path.join(os.environ['FOAMY_FAKEBIN'], 'monitors.json')\nrows = json.load(open(p))\nrows[2]['y'] = 100\njson.dump(rows, open(p, 'w'))\nPY", inflightC)
  }
  function inflightC() {
    eq(shell.service.commandProc.running, true, "still in flight when the event arrives")
    shell.service.hyprlandEvents.onRawEvent({
      name: "monitoraddedv2"
    })
    until(function () {
      return shell.service.statusRuns >= shell.runsBefore + 2 && displayIdle()
    }, "the follow-up run", inflightD)
  }
  function inflightD() {
    eq(shell.service.liveMonitors[2].y, 100, "the change made during the run arrives")
    eq(shell.service.statusRuns, shell.runsBefore + 2, "exactly one follow-up run")
    eq(shell.service.statusPending, false, "nothing left pending")
    // Every output gone for a moment (a KVM switch, undocking): that status
    // run fails, and the next good one must clear its error.
    shell.sh("rm -f \"$FOAMY_CALLS.hyprdelay\"; cd \"$FOAMY_FAKEBIN\" && cp monitors.json monitors.json.kept && printf '[]' > monitors.json", function () {
      shell.service.refresh()
      until(function () {
        return shell.service.error === "No connected displays" && displayIdle()
      }, "the failed status run", statusErrorA)
    })
  }
  function statusErrorA() {
    eq(shell.service.error, "No connected displays", "a failed status run shows its error")
    eq(shell.service.liveMonitors.length, 3, "a failed status run keeps the displays it had")
    shell.sh("cd \"$FOAMY_FAKEBIN\" && mv monitors.json.kept monitors.json", function () {
      shell.service.refresh()
      until(function () {
        return shell.service.error === "" && shell.service.liveMonitors.length === 3 && displayIdle()
      }, "the next good status run", statusErrorB)
    })
  }
  function statusErrorB() {
    eq(shell.service.error, "", "the next good status run clears it")
    eq(shell.service.liveMonitors.length, 3, "the displays are back")
    panel(0).open()
    until(function () {
      var view = panel(0).popup.bodyItem
      return view && view.brightnessAvailable && displayIdle() && brightnessIdle()
    }, "the popup's brightness read", stepFive)
  }
  function stepFive() {
    var first = panel(0)
    var view = first.popup.bodyItem
    check(view !== null, "body built on open")
    eq(shell.service.demanded, true, "open popup raises demand")
    if (!view) {
      shell.finish()
      return
    }
    eq(view.selectedMonitor, shell.service.transaction.draft[0].id, "the focused display is selected")
    eq(view.brightnessAvailable, true, "brightness read for the open popup")
    eq(view.brightnessPercent, 50, "brightness value")
    eq(view.cursorKey, "", "no cursor highlight on open")
    // The tab row is one stop: h/l move along it, Enter opens a tab.
    view.moveRequested(0, 1)
    eq(view.cursorKey, "tabs", "first move lands on the tab row")
    view.moveRequested(1, 0)
    eq(view.activeTab, "Display", "l moves along the tabs and opens none")
    view.activateRequested()
    eq(view.activeTab, "Advanced", "Enter opens the tab l moved to")
    eq(view.cursorKey, "tabs", "the cursor stays on the tab row")
    view.moveRequested(0, 1)
    eq(view.cursorKey, "textSize", "j walks into the tab")
    view.moveRequested(0, -1)
    eq(view.cursorKey, "tabs", "k goes back to the tab row")
    check(view.stops.indexOf("save") > 0 && view.stops.indexOf("discard") > 0, "pending change adds Discard and Save")
    shell.key(view, "w")
    eq(view.activeTab, "Wireless", "w opens Wireless")
    // The row's cursor follows: Enter on the row keeps Wireless open.
    view.activateRequested()
    eq(view.activeTab, "Wireless", "w puts the tab row's cursor on Wireless")
    eq(shell.service.wirelessWanted, true, "the Wireless tab wants a scan")
    view.setTab("Display")
    eq(shell.service.wirelessWanted, false, "leaving Wireless releases it")
    view.place("identify")
    view.itemFor("tabs").hovered()
    eq(view.cursorKey, "tabs", "a hovered tab takes the panel's one cursor")
    check(shell.findText(view.itemFor("box:1"), "2\n" + view.friendlyDisplayName(view.enabledMonitorInfos[1])) !== null, "itemFor finds the display box its key names")
    // The scene has no disconnected or mirrored display: turn the selected
    // one off in the draft for an offline row, then on again where it was.
    shell.keptPosition = {
      x: view.selected.x,
      y: view.selected.y
    }
    view.toggleDisplay()
    until(function () {
      return view.offlineMonitors.length === 1 && displayIdle()
    }, "the display turned off in the draft", stepFiveOffline)
  }
  property var keptPosition: null
  function stepFiveOffline() {
    var view = panel(0).popup.bodyItem
    view.place("box:0")
    var label = view.friendlyDisplayName(view.offlineMonitors[0]) + " · " + view.tr("Off")
    check(shell.findText(view.itemFor("offline:0"), label) !== null, "itemFor finds the offline row its key names")
    view.edit({
      disabled: false,
      x: shell.keptPosition.x,
      y: shell.keptPosition.y
    })
    until(function () {
      return view.offlineMonitors.length === 0 && displayIdle()
    }, "the display on again in the draft", stepFiveMove)
  }
  function stepFiveMove() {
    var first = panel(0)
    var view = first.popup.bodyItem
    eq(shell.service.changeCount, 1, "the display is back as it was: one unsaved change")
    view.place("box:1")
    shell.key(view, "m")
    check(view.moving !== "", "m picks up the display under the cursor")
    var before = shell.service.transaction.draft.find(function (m) {
      return m.name === view.moving
    }).x
    // Three presses before the helper answers still add up to 30 px.
    view.moveRequested(1, 0)
    view.moveRequested(1, 0)
    view.moveRequested(1, 0)
    shell.runsBefore = before
    view.activateRequested()
    eq(view.moving, "", "Enter drops it")
    eq(view.LayoutMirroring.enabled, shell.lang === "ar", "popup body mirrors in RTL only")
    // The plugin has no settings page: no Settings button.
    eq(view.band.settingsButton.visible, false, "no Settings button")
    view.closeRequested()
    eq(first.opened, false, "Esc closes")
    // A second bar's popup is open while three bars step brightness.
    panel(1).open()
    // Brightness from three bars at once: one DDC job at a time.
    for (var i = 0; i < 3; i++)
      shell.service.changeBrightness(shell.service.liveMonitors[i].name, {
        delta: 5
      }, panel(i))
    until(function () {
      var moved = shell.service.transaction.draft.find(function (m) {
        return m.name === "DP-1"
      })
      return moved.x === shell.runsBefore + 30 && displayIdle() && brightnessIdle() && shell.service.brightness["DP-2"] && shell.service.brightness["DP-2"].percent === 55
    }, "the nudges and the wheel steps", stepSix)
  }

  function stepSix() {
    var draft = shell.service.transaction.draft
    eq(draft.find(function (m) {
      return m.name === "DP-1"
    }).x, shell.runsBefore + 30, "three quick arrows nudge the display by 30 px")
    eq(shell.service.brightness["DP-2"].percent, 55, "a wheel step before the first read lands after it")
    // DP-1 and DP-2 had no reading: both steps waited for a read and show the
    // OSD once it landed, at the new level (50 + 5).
    check(mockBar.summoned.length >= 2 && mockBar.summoned.every(function (s) {
      return s.id === "omarchy.osd" && s.payload.icon === "brightness" && s.payload.value === 55
    }), "every waited step shows the Omarchy OSD at the new level: " + JSON.stringify(mockBar.summoned))
    eq(shell.service.brightnessProc.running, false, "brightness queue drained")
    panel(1).close()
    // The level changed elsewhere (laptop keys, the monitor's buttons) while
    // every popup was closed: a wheel step after the burst re-reads first.
    var aged = Object.assign({}, shell.service.brightness)
    aged["DP-2"] = {
      available: true,
      percent: 55,
      at: Date.now() - 10000
    }
    shell.service.brightness = aged
    shell.sh("printf 80 > \"$FOAMY_CALLS.brightness.DP-2\"", stepSixB)
  }

  function stepSixB() {
    eq(shell.service.changeBrightness("DP-2", {
      delta: 5
    }, panel(2)), 0, "a stale level is read again before stepping")
    until(function () {
      return brightnessIdle() && shell.service.brightness["DP-2"].percent === 85
    }, "the re-read step", stepSixC)
  }

  function stepSixC() {
    eq(shell.service.brightness["DP-2"].percent, 85, "the step lands on the fresh level (80 + 5)")
    eq(shell.service.changeBrightness("DP-2", {
      delta: 5
    }, panel(2)), 90, "steps within the burst reuse it")
    // An explicit level queued behind a read keeps later steps relative to it.
    var unknown = Object.assign({}, shell.service.brightness)
    delete unknown["DP-1"]
    shell.service.brightness = unknown
    eq(shell.service.changeBrightness("DP-1", {
      value: 40
    }, null), 0, "an unread display queues the level")
    eq(shell.service.changeBrightness("DP-1", {
      delta: 5
    }, null), 0, "and the following step")
    // A step waiting on a stale reading, then an explicit level: the level wins for good.
    var stale = Object.assign({}, shell.service.brightness)
    stale["eDP-1"] = {
      available: true,
      percent: 30,
      at: Date.now() - 10000
    }
    shell.service.brightness = stale
    eq(shell.service.changeBrightness("eDP-1", {
      delta: 5
    }, null), 0, "a step on a stale reading waits for a read")
    eq(shell.service.changeBrightness("eDP-1", {
      value: 40
    }, null), 40, "an explicit level is written at once")
    eq(shell.service.brightnessAfterRead["eDP-1"], undefined, "and supersedes the waiting step")
    until(function () {
      return brightnessIdle() && Object.keys(shell.service.brightnessAfterRead).length === 0
    }, "the queued levels", hangA)
  }

  // ---- A hung DDC job (fake: $FOAMY_CALLS.ddchang, ignores SIGTERM) ----
  // It ends at the deadline (SIGTERM, then SIGKILL 2 s later) and the
  // brightness change queued behind it still lands.
  function hangA() {
    eq(shell.service.brightness["DP-1"].percent, 45, "40 then +5 lands on 45, not the hardware level + 5")
    eq(shell.service.brightness["eDP-1"].percent, 40, "the explicit level stays after the read lands")
    eq(shell.service.brightnessAfterRead["eDP-1"], undefined, "no stale step left behind")
    eq(Object.keys(shell.service._stepRequester).length, 0, "no requester kept after its step")
    shell.service.brightnessTimeoutSeconds = 1
    shell.sh("touch \"$FOAMY_CALLS.ddchang\"", hangB)
  }
  function hangB() {
    var unknown = Object.assign({}, shell.service.brightness)
    delete unknown["DP-1"]
    shell.service.brightness = unknown
    eq(shell.service.changeBrightness("DP-1", {
      delta: 5
    }, null), 0, "a step on an unread display waits for its read")
    // The fake ignores SIGTERM, so the job lives until the SIGKILL at 3 s.
    wait.after(600, hangC)
  }
  function hangC() {
    eq(shell.service.brightnessProc.running, true, "the read hangs")
    eq(shell.service.changeBrightness("eDP-1", {
      value: 30
    }, null), 30, "a later level is accepted")
    shell.sh("rm -f \"$FOAMY_CALLS.ddchang\"", function () {
      until(function () {
        return brightnessIdle() && shell.service.brightness["DP-1"] !== undefined
      }, "the hung read's deadline", hangD)
    })
  }
  function hangD() {
    eq(shell.service.brightnessProc.running, false, "the hung read ended at its deadline")
    eq(shell.service.brightness["DP-1"].available, false, "a timed-out read is a failed read")
    eq(Object.keys(shell.service.brightnessAfterRead).length, 0, "no step left waiting on the hung read")
    eq(Object.keys(shell.service.brightnessWrites).length, 0, "the level queued behind it was written")
    shell.service.brightnessTimeoutSeconds = 20
    shell.service.readBrightness("eDP-1")
    until(brightnessIdle, "the read after the hang", errorsA)
  }

  // ---- Brightness and Advanced errors clear after the next good job ----
  // Fakes: $FOAMY_CALLS.ddcfail refuses brightness writes, .textfail the text size.
  function advancedIdle() {
    return !shell.service.advancedBusy && displayIdle()
  }
  function errorsA() {
    shell.sh("touch \"$FOAMY_CALLS.ddcfail\"", function () {
      eq(shell.service.setBrightness("DP-2", 70), 70, "a level the display will refuse")
      until(brightnessIdle, "the refused write", errorsB)
    })
  }
  function errorsB() {
    eq(shell.service.error, "DDC write failed on DP-2", "a failed brightness write shows its error")
    shell.sh("rm -f \"$FOAMY_CALLS.ddcfail\"", function () {
      shell.service.setBrightness("DP-2", 75)
      until(brightnessIdle, "the next brightness write", errorsC)
    })
  }
  function errorsC() {
    eq(shell.service.error, "", "the next good brightness write clears it")
    shell.sh("touch \"$FOAMY_CALLS.textfail\"", function () {
      shell.service.setTextSize(12)
      until(advancedIdle, "the refused text size", errorsD)
    })
  }
  function errorsD() {
    eq(shell.service.error, "text size refused", "a failed Advanced job shows its error")
    shell.sh("rm -f \"$FOAMY_CALLS.textfail\"", function () {
      shell.service.setTextSize(12)
      until(advancedIdle, "the next text size", errorsE)
    })
  }
  function errorsE() {
    eq(shell.service.error, "", "the next good Advanced job clears it")
    // An error that replaced the brightness one since is not its to clear.
    shell.sh("touch \"$FOAMY_CALLS.ddcfail\"", function () {
      shell.service.setBrightness("DP-2", 80)
      until(brightnessIdle, "another refused write", function () {
        shell.service.error = "A display test is already running"
        shell.sh("rm -f \"$FOAMY_CALLS.ddcfail\"", function () {
          shell.service.setBrightness("DP-2", 85)
          until(brightnessIdle, "a good write after another error", errorsF)
        })
      })
    })
  }
  function errorsF() {
    eq(shell.service.error, "A display test is already running", "a good brightness write leaves a later display error")
    shell.service.error = ""
    // The cursor size goes to gsettings and hyprctl (runtime.py checks their calls).
    shell.service.setCursorSize(48)
    until(advancedIdle, "the cursor size", errorsG)
  }
  function errorsG() {
    eq(shell.service.error, "", "a cursor size both tools take is no error")
    droppedA()
  }

  // ---- A pick nothing will apply shows the setting in use again ----
  // A field is disabled while another Advanced job or a display test runs,
  // but a list opened before that still takes a pick (Qt keeps an open
  // popup's list enabled). The fake text size command runs until
  // $FOAMY_CALLS.texthold is gone.
  function droppedA() {
    panel(0).open()
    until(function () {
      return panel(0).popup.bodyItem && advancedIdle()
    }, "the popup for the dropped picks", function () {
      panel(0).popup.bodyItem.setTab("Advanced")
      shell.sh("touch \"$FOAMY_CALLS.texthold\"", function () {
        shell.service.setTextSize(14)
        until(function () {
          return shell.service.advancedBusy
        }, "the held text size job", droppedB)
      })
    })
  }
  function droppedB() {
    var view = panel(0).popup.bodyItem
    pick(view, "cursorSize", view.dropdownFor("cursorSize").currentValue === "36" ? "48" : "36")
    check(shows(view, "cursorSize", view.dropdownFor("cursorSize").currentValue), "a cursor size picked while another Advanced job runs shows the size in use again")
    pick(view, "textSize", view.dropdownFor("textSize").currentValue === "16" ? "20" : "16")
    check(shows(view, "textSize", view.dropdownFor("textSize").currentValue), "a text size picked while another Advanced job runs shows the size in use again")
    shell.sh("rm -f \"$FOAMY_CALLS.texthold\"", function () {
      until(advancedIdle, "the held text size job's end", refusedA)
    })
  }

  // ---- A refused pick shows the setting in use again at once ----
  // A dropdown keeps showing a pick until its value follows; a pick the host
  // command or the helper refuses never changes the value.
  property var refusedKept: null
  function dropdownIn(item) {
    if (!item)
      return null
    if ("shownValue" in item && "saveFailed" in item)
      return item
    for (var i = 0; i < item.children.length; i++) {
      var found = dropdownIn(item.children[i])
      if (found)
        return found
    }
    return null
  }
  // Picks `value` in the view's `key` field as its option list does.
  function pick(view, key, value) {
    dropdownIn(view.dropdownFor(key)).select(value)
  }
  // Whether the trigger of the view's `key` field shows `value`'s label.
  function shows(view, key, value) {
    var field = view.dropdownFor(key)
    var option = field.options.find(function (o) {
      return String(o.value) === value
    })
    return shell.findText(field, option ? String(option.label) : value) !== null
  }
  function refusedA() {
    shell.sh("touch \"$FOAMY_CALLS.textfail\"", function () {
      panel(0).open()
      until(function () {
        return panel(0).popup.bodyItem && advancedIdle()
      }, "the popup for the refused picks", refusedB)
    })
  }
  function refusedB() {
    var view = panel(0).popup.bodyItem
    view.setTab("Advanced")
    var size = view.dropdownFor("textSize").currentValue === "16" ? "20" : "16"
    pick(view, "textSize", size)
    check(shows(view, "textSize", size), "the picked text size shows while it applies")
    until(function () {
      return shell.service.error === "text size refused" && advancedIdle()
    }, "the refused text size pick", refusedC)
  }
  function refusedC() {
    var view = panel(0).popup.bodyItem
    check(shows(view, "textSize", view.dropdownFor("textSize").currentValue), "a refused text size shows the size in use again")
    shell.service.error = ""
    // The selected display goes away before the helper takes the pick.
    shell.refusedKept = view.selectedMonitor
    view.setTab("Display")
    view.selectMonitor(shell.service.transaction.draft.find(function (m) {
      return m.name === "DP-1"
    }).id)
    shell.sh("rm -f \"$FOAMY_CALLS.textfail\"; cd \"$FOAMY_FAKEBIN\" && cp monitors.json monitors.json.kept && python3 -c 'import json; rows = json.load(open(\"monitors.json\")); json.dump([r for r in rows if r[\"name\"] != \"DP-1\"], open(\"monitors.json\", \"w\"))'", function () {
      pick(view, "resolution", "1280x720")
      check(shows(view, "resolution", "1280x720"), "the picked resolution shows while the helper takes it")
      // Another display's refused pick of the same mode is not this pick.
      shell.service.commandRefused("patch", {
        id: shell.service.transaction.draft.find(function (m) {
          return m.name !== "DP-1"
        }).id,
        changes: {
          width: 1280,
          height: 720
        }
      })
      check(shows(view, "resolution", "1280x720"), "a refused pick of another display leaves this display's pick on show")
      until(function () {
        return shell.service.error === "Display is disconnected" && displayIdle()
      }, "the refused resolution pick", refusedD)
    })
  }
  function refusedD() {
    var view = panel(0).popup.bodyItem
    check(shows(view, "resolution", view.dropdownFor("resolution").currentValue), "a refused resolution shows the mode in use again")
    heldA()
  }

  // ---- Refusals that answer while a display box is dragged ----
  // The service holds every helper answer until the drop. Two picks for the
  // display that went away answer during a drag (each helper run waits 1 s
  // in the fake hyprctl), and the dropped box's own patch starts before the
  // held answers are applied: each refusal must still reach its own field.
  function heldA() {
    var view = panel(0).popup.bodyItem
    // A pick then stays on show until a refusal ends it, however slow the runs.
    dropdownIn(view.dropdownFor("resolution")).pickHoldMs = 600000
    dropdownIn(view.dropdownFor("orientation")).pickHoldMs = 600000
    shell.sh("printf 1 > \"$FOAMY_CALLS.hyprdelay\"", function () {
      until(displayIdle, "no helper run before the held picks", function () {
        pick(view, "resolution", "1280x720")
        pick(view, "orientation", "1")
        view.dragging = true
        // The second pick's run is queued behind the first, and a status
        // run waits for the drop: an empty queue means both picks' runs
        // have ended and both answers came during the drag.
        until(function () {
          return !shell.service.commandProc.running && shell.service.commands.length === 0
        }, "both refusals answered during the drag", heldB)
      })
    })
  }
  function heldB() {
    var view = panel(0).popup.bodyItem
    check(shows(view, "resolution", "1280x720") && shows(view, "orientation", "1"), "answers during a drag wait for the drop")
    // The drop as the box's onReleased does it: the drag ends, then the
    // dropped box's patch (another display, put where it already is).
    var dropped = shell.service.transaction.draft.find(function (m) {
      return m.name === "eDP-1"
    })
    view.dragging = false
    view.moveMonitor(dropped.name, dropped.x, dropped.y)
    until(displayIdle, "the drop's patch", heldC)
  }
  function heldC() {
    var view = panel(0).popup.bodyItem
    check(shows(view, "resolution", view.dropdownFor("resolution").currentValue), "a resolution refused during a drag shows the mode in use again")
    check(shows(view, "orientation", view.dropdownFor("orientation").currentValue), "an orientation refused during a drag shows the orientation in use again")
    dropdownIn(view.dropdownFor("resolution")).pickHoldMs = 10000
    dropdownIn(view.dropdownFor("orientation")).pickHoldMs = 10000
    shell.sh("rm -f \"$FOAMY_CALLS.hyprdelay\"; cd \"$FOAMY_FAKEBIN\" && mv monitors.json.kept monitors.json", function () {
      shell.service.refresh()
      until(function () {
        var back = shell.service.transaction.draft.find(function (m) {
          return m.name === "DP-1"
        })
        return back && back.connected && shell.service.liveMonitors.length === 3 && displayIdle()
      }, "the display back", refusedE)
    })
  }
  function refusedE() {
    var view = panel(0).popup.bodyItem
    view.selectMonitor(shell.refusedKept)
    view.setTab("Advanced")
    shell.service.error = ""
    // A second GDK_SCALE line makes the helper refuse every GTK scale.
    shell.sh("cd \"$HOME/.config/hypr\" && cp monitors.lua monitors.lua.kept && printf 'hl.env(\"GDK_SCALE\", \"2\")\\n' >> monitors.lua", function () {
      pick(view, "gtkScale", "3")
      pick(view, "gtkScale", "4")
      // The refusal of an earlier pick leaves a newer pick on show.
      shell.service.commandRefused("gtk-scale", {
        value: 3
      })
      check(shows(view, "gtkScale", "4"), "a refusal of an earlier GTK scale pick keeps the newer pick on show")
      until(function () {
        return shell.service.error === "Remove duplicate GDK_SCALE settings from monitors.lua" && displayIdle()
      }, "the refused GTK scale picks", refusedF)
    })
  }
  function refusedF() {
    var view = panel(0).popup.bodyItem
    check(shows(view, "gtkScale", view.dropdownFor("gtkScale").currentValue), "a refused GTK scale shows the scale in use again")
    shell.sh("cd \"$HOME/.config/hypr\" && mv monitors.lua.kept monitors.lua", function () {
      shell.service.error = ""
      shell.service.refresh()
      until(function () {
        return shell.service.gtkScale.error === "" && shell.service.gtkScale.value === 2 && displayIdle()
      }, "the GTK scale readable again", function () {
        panel(0).close()
        lifeA()
      })
    })
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
    until(function () {
      return shell.service.members === 2 && !shell.service.scanning && displayIdle()
    }, "the unplugged bar", lifeB)
  }
  function lifeB() {
    eq(shell.service.members, 2, "two bars left")
    eq(shell.service.wirelessWanted, false, "a destroyed view releases Wireless")
    eq(shell.service.arrangementDragActive, false, "a destroyed view releases its drag")
    eq(shell.service.demanded, false, "a destroyed open popup releases its demand")
    eq(shell.service.scanning, false, "no scan or dependency check for a view that is gone")
    eq(shell.service.teardowns, 0, "other bars keep the service")
    shell.runsBefore = shell.service.statusRuns
    shell.service.refresh()
    until(function () {
      return shell.service.statusRuns > shell.runsBefore && displayIdle()
    }, "the status after the drag", lifeC)
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
    until(function () {
      return shell.service.members === 3 && shell.leaders() === 1
    }, "the rebuilt bars", lifeE)
  }
  function lifeE() {
    eq(shell.service.members, 3, "bars rebuilt")
    eq(shell.service.releaseTimer.running, false, "the release grace stopped with the rebuild")
    eq(shell.service.teardowns, 0, "a rebuild within the grace period does not tear down")
    eq(shell.service.active, true, "service still active")
    eq(shell.service.scanRunning, true, "the scan survives the rebuild")
    eq(shell.leaders(), 1, "one leader after the rebuild")
    // ---- A running trial against every UI state ----
    // Every popup is closed and no body is built yet: the trial must open a
    // popup by itself (offscreen no bar is on the focused output, so the
    // leader's), and the body built then must land on Revert.
    eq(shell.openCount(), 0, "every popup closed before the trial")
    shell.setPhase("testing", function () {
      until(function () {
        var view = shell.leaderPanel().popup.bodyItem
        return shell.service.testing && shell.leaderPanel().opened && view && view.cursorKey === "revert" && displayIdle()
      }, "the trial", trialA)
    })
  }
  function trialA() {
    eq(shell.service.testing, true, "the trial arrives through the state file")
    eq(shell.leaderPanel().opened, true, "the trial opens the popup by itself")
    eq(shell.openCount(), 1, "one popup shows the trial")
    var view = shell.leaderPanel().popup.bodyItem
    if (!view) {
      shell.finish()
      return
    }
    eq(view.cursorKey, "revert", "a view built during the trial lands on Revert")
    eq(JSON.stringify(view.stops), JSON.stringify(["revert", "keep"]), "only Revert and Keep take the cursor")
    // A list opened before the trial began still takes a pick; nothing
    // changes a display during the trial.
    pick(view, "resolution", view.dropdownFor("resolution").currentValue === "1280x720" ? "1920x1080" : "1280x720")
    check(shows(view, "resolution", view.dropdownFor("resolution").currentValue), "a resolution picked during a trial shows the mode in use again")
    view.setTab("Advanced")
    check(view.footerShown, "the trial footer shows on Advanced")
    view.setTab("Wireless")
    check(view.footerShown, "and on Wireless")
    shell.leaderPanel().close()
    until(function () {
      return shell.openCount() === 1
    }, "the trial popup to reopen", trialB, 5000)
  }
  function trialB() {
    eq(shell.openCount(), 1, "closing the popup during a trial reopens it")
    var view = shell.leaderPanel().popup.bodyItem
    eq(view.cursorKey, "revert", "the reopened trial lands on Revert")
    // Esc during a trial reverts it: the helper records the decision only for
    // the running trial's token.
    view.closeRequested()
    until(function () {
      return shell.service.transaction.decision === "revert" && displayIdle()
    }, "Esc sent revert", trialB2)
  }
  function trialB2() {
    eq(shell.service.transaction.decision, "revert", "Esc reverts the running trial")
    eq(shell.service.error, "", "the helper took the revert for this trial")
    eq(shell.leaderPanel().opened, true, "the trial popup is shown after Esc")
    shell.setPhase("idle", function () {
      until(function () {
        return !shell.service.testing && displayIdle()
      }, "the trial's end", trialC)
    })
  }
  function trialC() {
    eq(shell.service.testing, false, "trial over")
    // A trial whose worker is gone (killed, crashed): the busy poll's next
    // status reverts it and says so.
    shell.setPhase("dead", function () {
      until(function () {
        return shell.service.transaction.error !== "" && !shell.service.busy && displayIdle()
      }, "the dead trial's recovery", trialD)
    })
  }
  function trialD() {
    eq(shell.service.transaction.phase, "idle", "a dead trial goes idle")
    var view = shell.leaderPanel().popup.bodyItem
    check(shell.findText(view, "The display test stopped unexpectedly. The previous settings were restored.") !== null, "the recovery says so on the error line")
    shell.leaderPanel().close()
    until(function () {
      return !shell.service.scanning
    }, "the scan to stop with the last popup", wifiA)
  }

  // ---- Wireless receivers cached in the service (2-minute TTL) ----
  // The fake FluxCast lists $FOAMY_CALLS.peers after $FOAMY_CALLS.scandelay s.
  property int scansBefore: 0
  // The first item under `item` (depth first) whose text is `text`.
  function findText(item, text) {
    if (!item)
      return null
    if (item.text === text)
      return item
    for (var i = 0; i < item.children.length; i++) {
      var found = findText(item.children[i], text)
      if (found)
        return found
    }
    return null
  }
  function addresses() {
    return shell.service.wirelessPeers.map(function (p) {
      return p.address
    }).join(",")
  }
  function wifiA() {
    eq(shell.service.scanning, false, "no scan left over before the cache checks")
    shell.service.wirelessPeers = []
    shell.service.wirelessScannedAt = 0
    shell.scansBefore = shell.service.wirelessScanRuns
    shell.sh("printf '[1] 7A:2D:91:40:0B:CE <b>Living</b> Room TV via NetworkManager\\n[2] 02:11:22:33:44:55 via NetworkManager\\n' > \"$FOAMY_CALLS.peers\"; printf 1.2 > \"$FOAMY_CALLS.scandelay\"", wifiB)
  }
  function wifiB() {
    panel(0).open()
    panel(0).popup.bodyItem.setTab("Wireless")
    // Process.running notifies once the process has started.
    until(function () {
      return panel(0).popup.bodyItem.scanSpinning
    }, "the first scan", wifiB2)
  }
  function wifiB2() {
    var view = panel(0).popup.bodyItem
    eq(shell.service.scanning, true, "showing Wireless with nothing cached starts a scan")
    eq(view.scanSpinning, true, "the Scan glyph spins during the first scan")
    eq(view.itemFor("scan").spinning, true, "FoamyAction spinning is set")
    eq(view.itemFor("scan").actionEnabled, false, "Scan is inert while it runs")
    eq(view.scanIndicatorShown, true, "an empty list shows the searching row")
    until(function () {
      return shell.service.scanRunning
    }, "the scan process", wifiC)
  }
  function wifiC() {
    eq(shell.service.scanRunning, true, "the scan runs")
    eq(shell.service.wirelessScanRuns, shell.scansBefore + 1, "one scan process")
    // Every bar shares the service: more requests while it runs start nothing.
    shell.service.checkWireless()
    shell.service.startWirelessScan()
    eq(shell.service.wirelessScanRuns, shell.scansBefore + 1, "still one scan for every bar")
    until(function () {
      return !shell.service.scanning && shell.service.wirelessScanState === "results"
    }, "the scan's results", wifiD)
  }
  function wifiD() {
    var view = panel(0).popup.bodyItem
    eq(shell.addresses(), "7A:2D:91:40:0B:CE,02:11:22:33:44:55", "the scan lists both receivers")
    eq(shell.service.wirelessScanState, "results", "results state")
    check(shell.service.wirelessScannedAt > 0, "the finished scan is timestamped")
    eq(view.scanSpinning, false, "the glyph stops with the scan")
    eq(view.scanIndicatorShown, false, "no searching row with results")
    // itemFor finds the row its key names, wherever the cursor is.
    check(view.itemFor("peer:1") !== null && view.itemFor("peer:1") !== view.itemFor("peer:0"), "both receivers are listed")
    // A nearby device chooses its own name: markup in it is shown as text.
    var label = shell.findText(view.itemFor("peer:0"), "<b>Living</b> Room TV")
    check(label !== null && label.textFormat === Text.PlainText, "a receiver name is shown as plain text")
    panel(0).close()
    eq(shell.service.demanded, false, "popup closed")
    eq(shell.service.wirelessPeers.length, 2, "closing the popup keeps the receivers in the service")
    // Next scan: one receiver gone, one renamed, one new (listed first).
    shell.sh("printf '[1] 0A:0B:0C:0D:0E:0F Den via NetworkManager\\n[2] 02:11:22:33:44:55 Projector via NetworkManager\\n' > \"$FOAMY_CALLS.peers\"; printf 1.5 > \"$FOAMY_CALLS.scandelay\"", function () {
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
    check(view.itemFor("peer:1") !== null && view.itemFor("peer:1") !== view.itemFor("peer:0"), "cached receivers are listed")
    until(function () {
      return panel(1).popup.bodyItem.scanSpinning
    }, "the refresh", wifiE2)
  }
  function wifiE2() {
    var view = panel(1).popup.bodyItem
    eq(shell.service.scanning, true, "and refreshes it")
    eq(shell.service.wirelessRefreshing, true, "silently")
    eq(view.scanSpinning, true, "only the Scan glyph spins")
    eq(view.scanIndicatorShown, false, "no searching row over a cached list")
    check(view.stops.indexOf("peer:1") > 0, "cached receivers keep cursor stops during the refresh")
    until(function () {
      return shell.service.scanRunning
    }, "the refresh's scan process", wifiF)
  }
  function wifiF() {
    eq(shell.service.wirelessScanRuns, shell.scansBefore + 2, "one refresh")
    eq(shell.addresses(), "7A:2D:91:40:0B:CE,02:11:22:33:44:55", "the list holds still while it refreshes")
    until(function () {
      return !shell.service.scanning && shell.service.wirelessScanState === "results"
    }, "the refresh's results", wifiG)
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
    until(function () {
      return panel(1).popup.bodyItem.scanIndicatorShown
    }, "the new scan", wifiG2)
  }
  function wifiG2() {
    eq(panel(1).popup.bodyItem.scanIndicatorShown, true, "the searching row shows for the new scan")
    until(function () {
      return !shell.service.scanning && shell.service.wirelessPeers.length === 2
    }, "the new scan's results", wifiH)
  }
  function wifiH() {
    eq(shell.service.wirelessPeers.length, 2, "the new scan lists the receivers")
    // Picking a receiver during a refresh stops the scan, then casts.
    shell.sh("printf 5 > \"$FOAMY_CALLS.scandelay\"; printf '%s\\n' refresh-start >> \"$FOAMY_CALLS\"", function () {
      shell.service.wirelessScannedAt -= 30000
      panel(1).popup.bodyItem.scanOrStop()
      // runtime.py looks for the stop signal that FluxCast logs; a stop sent
      // before its handlers are in place would end it without that line.
      until(function () {
        return shell.service.scanRunning && shell.loggedAfter("refresh-start", "fluxcast-ready")
      }, "the Scan button's refresh reached FluxCast", wifiJ)
    })
  }
  function wifiJ() {
    var view = panel(1).popup.bodyItem
    eq(shell.service.scanRunning, true, "a refresh runs")
    eq(shell.service.wirelessPeers.length, 2, "the Scan button keeps the list too")
    view.connectPeer(shell.service.wirelessPeers[0])
    // A cast that starts at once sets "starting" in this same call.
    eq(shell.service.castPhase, "idle", "the pick waits for the scan to stop")
    check(shell.service.pendingCast !== null, "the pick is kept until the scan stopped")
    until(function () {
      return !shell.service.scanRunning && shell.service.castRunning
    }, "the cast after the scan", wifiK)
  }
  function wifiK() {
    eq(shell.service.scanRunning, false, "the refresh was stopped")
    eq(shell.service.pendingCast, null, "the pick was taken")
    // The fake FluxCast prints nothing here, so the bridge stays at "starting".
    eq(shell.service.castPhase, "starting", "the cast started after the scan")
    eq(shell.service.wirelessError, "", "the cast has no error")
    eq(shell.service.wirelessPeers.length, 2, "a stopped refresh keeps the list")
    shell.service.stopCast()
    panel(1).close()
    shell.sh("rm -f \"$FOAMY_CALLS.peers\" \"$FOAMY_CALLS.scandelay\"; touch \"$FOAMY_CALLS.stubborn\"", function () {
      until(function () {
        return !shell.service.castRunning
      }, "the cast to stop", scanStopA)
    })
  }

  // ---- A scan whose FluxCast ignores the stop (fake: $FOAMY_CALLS.stubborn) ----
  // The first stop is SIGINT to FluxCast; the watchdog's second signal makes
  // the bridge SIGTERM it. The watchdog runs at 500 ms here (12 s live).
  function scanStopA() {
    eq(shell.service.castPhase, "idle", "a stopped cast ends idle")
    eq(shell.service.wirelessError, "", "a stopped cast is no failure")
    var watchdog = shell.service.scanStopWatchdog
    check(watchdog !== undefined, "the scan has a stop watchdog")
    if (watchdog)
      watchdog.interval = 500
    shell.mark("stubborn-start", function () {
      shell.service.startWirelessScan()
      // The stop must reach a FluxCast that already ignores SIGINT; a stop
      // that came first would end it at once and prove nothing.
      until(function () {
        return shell.service.scanRunning && shell.loggedAfter("stubborn-start", "fluxcast-ready")
      }, "the stubborn FluxCast is ready", scanStopB)
    })
  }
  function scanStopB() {
    shell.service.cancelWirelessScan()
    var watchdog = shell.service.scanStopWatchdog
    eq(watchdog && watchdog.running, true, "a stopped scan arms its watchdog")
    wait.waitFor(function () {
      return !shell.service.scanRunning
    }, 6000, function (ok) {
      check(ok, "a scan that ignores its stop ends at the watchdog's second signal")
      eq(watchdog && watchdog.running, false, "the watchdog stops with the scan")
      eq(shell.service.wirelessScanState !== "error" && shell.service.wirelessScanState !== "scanning", true, "a stopped scan is no failure: " + shell.service.wirelessScanState)
      if (watchdog)
        watchdog.interval = 12000
      // A cast that reaches the receiver ($FOAMY_CALLS.casting) runs when
      // the last panel goes: the teardown must stop it.
      shell.sh("rm -f \"$FOAMY_CALLS.stubborn\"; touch \"$FOAMY_CALLS.casting\"", function () {
        shell.service.connectWirelessPeer({
          address: "0A:0B:0C:0D:0E:0F"
        }, "Den", "eDP-1")
        until(function () {
          return shell.service.castPhase === "casting"
        }, "a cast before the teardown", castingA)
      })
    })
  }
  function castingA() {
    eq(shell.service.activelyCasting, true, "the cast reached the receiver")
    eq(panel(0).barGlyph.codePointAt(0), 0xf037a, "an active cast shows the multi-display glyph")
    eq(panel(1).popup.bodyItem.wirelessPhaseLabel(), "Casting to Den", "the Wireless tab says what is shared")
    shell.mark("teardown-start", function () {
      shell.panelCount = 0
      until(function () {
        return shell.service.teardowns === 1 && !shell.service.scanRunning && !shell.service.castRunning
      }, "the teardown", stepEight)
    })
  }

  function stepEight() {
    // runtime.py looks for the cast's stop signal between teardown-start and
    // teardown-done. The bridge waits for FluxCast to exit, and the fake logs
    // the signal before it exits, so the line is written by now. After this
    // marker, the end of qs also signals FluxCast, which proves nothing.
    shell.mark("teardown-done", function () {
      eq(shell.service.castRunning, false, "the teardown stopped the cast")
      eq(shell.service.members, 0, "every panel gone")
      eq(shell.service.teardowns, 1, "teardown after the last panel left")
      eq(shell.service.active, false, "service idle")
      eq(shell.service.scanRunning, false, "scan stopped")
      eq(shell.service.commands.length, 0, "no queued commands after teardown")
      eq(shell.service.statusPending, false, "no pending refresh after teardown")
      shell.finish()
    })
  }

  // Runs a shell script; then() (optional) once it has exited.
  function sh(script, then) {
    var p = Qt.createQmlObject('import Quickshell.Io; Process {}', shell)
    if (then)
      p.exited.connect(function () {
        then()
      })
    p.command = ["sh", "-c", script]
    p.running = true
  }

  property int holdMs: Number(Quickshell.env("FOAMY_HOLD_MS") || 0)
  function finish() {
    console.log("FOAMY RESULT " + host + "/" + lang + " " + checks + " checks, " + failures + " failures")
    wait.after(Math.max(1, shell.holdMs), function () {
      console.log("FOAMY DONE")
      Qt.quit()
    })
  }
}
