import QtQuick
import QtTest
import Quickshell
import qs.Commons
import qs.Ui
import "harness"
import "plugin" as Monitor
import "plugin/kit"

// The popup's buttons (Turn off/on, Discard, Save, Revert, Keep settings)
// under a real pointer and the keys, offscreen with the fake hyprctl,
// brightness and gsettings of tests/fakebin.py (three displays): one bar
// panel runs the service, and a MonitorView of its own sits in a window the
// pointer reaches (a bar's popup is not on screen offscreen).
//
// For each button: the keys bring the cursor there and draw the keys' border
// (the accent; on Save and Keep settings the text or the background colour);
// the pointer entering takes the cursor, with the pointer's look and no keys'
// border; a click acts (the display turns off, the change is discarded, Save
// sends apply; in a trial Revert and Keep settings send their decision). Turn
// off with only one
// display left on stays a cursor stop with the keys' border, does nothing on
// a click, and its label reads at 4.5:1 on the button as drawn.
ShellRoot {
  id: shell
  readonly property string host: Quickshell.env("FOAMY_HOST")
  readonly property string lang: Quickshell.env("FOAMY_LANG") || "en"
  property int checks: 0
  property int failures: 0
  readonly property var service: Monitor.MonitorService

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

  FoamyWait {
    id: wait
  }
  TestEvent {
    id: ev
  }
  // Waits for condition(), records it as a check named `label`, then next().
  function until(condition, label, next, timeoutMs) {
    wait.waitFor(condition, timeoutMs || 15000, function (ok) {
      check(ok, "waited for: " + label)
      next()
    })
  }
  function displayIdle() {
    return !service.commandProc.running && !service.statusDebounce.running && service.commands.length === 0 && !service.statusPending
  }

  // The bar panel: its membership starts the service and the helper's status.
  FloatingWindow {
    implicitWidth: 200
    implicitHeight: 40
    color: "black"
    Monitor.Panel {
      bar: mockBar
      width: 40
      height: 30
    }
  }
  MockBar {
    id: mockBar
    moduleName: "foamy.monitor"
  }

  QtObject {
    id: mockHost
    property QtObject bar: mockBar
    readonly property bool opened: true
    function close() {
    }
    function switchPanel(direction) {
      return false
    }
  }
  FloatingWindow {
    id: window
    implicitWidth: 560
    implicitHeight: 1000
    color: FoamyPalette.background
    Loader {
      id: viewLoader
      active: false
      sourceComponent: Monitor.MonitorView {
        width: implicitWidth
        height: implicitHeight
        host: mockHost
      }
    }
  }

  // The button whose label is `text` (the host's Ui.Button or FoamyButton).
  function button(item, text) {
    if (!item)
      return null
    if (item.text === text && item.hasCursor !== undefined && item.clicked !== undefined && item.visible)
      return item
    for (var i = 0; i < item.children.length; i++) {
      var found = button(item.children[i], text)
      if (found)
        return found
    }
    return null
  }
  function labelOf(item, text) {
    if (!item)
      return null
    if (item !== null && item.text === text && item.font !== undefined && item.hasCursor === undefined)
      return item
    for (var i = 0; i < item.children.length; i++) {
      var found = labelOf(item.children[i], text)
      if (found)
        return found
    }
    return null
  }
  // The button's outline as drawn: the keys' border is the accent, or on a
  // primary's accent fill the text or the background colour.
  function keysBorder(b) {
    if (!b || b.border === undefined || b.border.width < 1)
      return false
    var c = b.border.color
    if (b.kind === "primary")
      return Qt.colorEqual(c, FoamyPalette.text) || Qt.colorEqual(c, FoamyPalette.background)
    return Qt.colorEqual(c, FoamyPalette.accent)
  }
  // The keys walk to `key` from the tab row; the cursor ends there with the
  // keys' look.
  function keysTo(view, key) {
    view.place("tabs")
    for (var n = 0; n < view.stops.length && view.cursorKey !== key; n++)
      view.moveRequested(0, 1)
  }
  // A real pointer move onto `item`'s centre, from outside every button.
  function pointerOnto(item) {
    ev.mouseMove(window.contentItem, 2, 2, -1, Qt.NoButton, Qt.NoModifier)
    ev.mouseMove(item, item.width / 2, item.height / 2, -1, Qt.NoButton, Qt.NoModifier)
  }
  function pointerAway() {
    ev.mouseMove(window.contentItem, 2, 2, -1, Qt.NoButton, Qt.NoModifier)
  }
  // Keys, then the pointer, on `text`'s button (stop `key`).
  function cursorChecks(view, text, key) {
    var b = button(view, text)
    check(b !== null, text + ": shown")
    if (!b)
      return null
    pointerAway()
    keysTo(view, key)
    eq(view.cursorKey, key, text + ": the keys reach it")
    check(b.hasCursor && keysBorder(b), text + ": the keys' cursor draws the keys' border (" + (b.border ? b.border.color : "no border") + ")")
    var keysEdge = b.border ? String(b.border.color) : ""
    view.place("tabs")
    pointerOnto(b)
    eq(view.cursorKey, key, text + ": the pointer entering takes the cursor")
    check(b.hasCursor && !keysBorder(b) && String(b.border ? b.border.color : "") !== keysEdge, text + ": the pointer's cursor draws no keys' border (" + (b.border ? b.border.color : "no border") + ")")
    return b
  }
  // How `item` is drawn over the window: its colour at the opacity of it and
  // its ancestors.
  function drawn(item, color, under) {
    var op = 1
    for (var it = item; it; it = it.parent)
      op *= it.opacity
    return Qt.tint(under, Qt.alpha(color, color.a * op))
  }

  Component.onCompleted: until(function () {
    return service.liveMonitors.length === 3 && service.statePath !== "" && displayIdle()
  }, "the startup status", start, 30000)

  function start() {
    viewLoader.active = true
    until(function () {
      return viewLoader.item && viewLoader.item.selectedMonitor !== ""
    }, "the view selects a display", power)
  }
  property var view: viewLoader.item

  // ---- Turn off ----
  function power() {
    var b = cursorChecks(view, view.tr("Turn off"), "power")
    if (!b)
      return finish()
    eq(view.selected.name, "eDP-1", "fixture: the focused display is selected")
    ev.mouseClick(b, b.width / 2, b.height / 2, Qt.LeftButton, Qt.NoModifier, -1)
    until(function () {
      return view.offlineMonitors.length === 1 && service.changeCount === 1 && displayIdle()
    }, "a click on Turn off turns the display off in the draft", footer)
  }

  // ---- Discard and Save ----
  function footer() {
    cursorChecks(view, view.tr("Save"), "save")
    var b = cursorChecks(view, view.tr("Discard"), "discard")
    if (!b)
      return finish()
    ev.mouseClick(b, b.width / 2, b.height / 2, Qt.LeftButton, Qt.NoModifier, -1)
    until(function () {
      return view.offlineMonitors.length === 0 && service.changeCount === 0 && displayIdle()
    }, "a click on Discard discards the change", inertA)
  }

  // ---- Turn off with one display left on: inert ----
  function inertA() {
    view.selectMonitor(service.transaction.draft[0].id)
    view.toggleDisplay()
    until(function () {
      return view.offlineMonitors.length === 1 && displayIdle()
    }, "fixture: eDP-1 off", inertB)
  }
  function inertB() {
    view.selectMonitor(service.transaction.draft[1].id)
    view.toggleDisplay()
    until(function () {
      return view.offlineMonitors.length === 2 && displayIdle()
    }, "fixture: DP-1 off", inertC)
  }
  function inertC() {
    view.selectMonitor(service.transaction.draft[2].id)
    eq(view.activeCount, 1, "fixture: one display left on")
    var text = view.tr("Turn off")
    var b = button(view, text)
    check(b !== null, "inert Turn off: shown")
    if (!b)
      return finish()
    pointerAway()
    keysTo(view, "power")
    eq(view.cursorKey, "power", "inert Turn off: still a cursor stop")
    check(keysBorder(b), "inert Turn off: the keys' cursor draws the keys' border")
    var label = labelOf(b, text)
    var under = window.color
    var fill = drawn(b, b.color, under)
    var ink = label ? drawn(label, label.color, fill) : under
    var ratio = FoamyPalette.contrastRatio(ink, fill)
    check(ratio >= 4.5, "inert Turn off: the label reads on the button as drawn: " + ratio.toFixed(2) + ":1")
    var changes = service.changeCount
    ev.mouseClick(b, b.width / 2, b.height / 2, Qt.LeftButton, Qt.NoModifier, -1)
    wait.after(600, function () {
      check(service.changeCount === changes && view.activeCount === 1 && displayIdle(), "a click on the inert Turn off does nothing")
      var discard = button(view, view.tr("Discard"))
      ev.mouseClick(discard, discard.width / 2, discard.height / 2, Qt.LeftButton, Qt.NoModifier, -1)
      until(function () {
        return view.offlineMonitors.length === 0 && service.changeCount === 0 && displayIdle()
      }, "Discard brings every display back", trialA)
    })
  }

  // ---- Save, then a trial: Revert, then Keep settings ----
  // The helper commands the service ran, in order.
  property var helperRuns: []
  Connections {
    target: shell.service.commandProc
    function onRunningChanged() {
      if (shell.service.commandProc.running)
        shell.helperRuns = shell.helperRuns.concat([shell.service.commandProc.action])
    }
  }
  function trialA() {
    view.selectMonitor(service.transaction.draft[1].id)
    view.toggleDisplay()
    until(function () {
      return service.changeCount === 1 && displayIdle()
    }, "fixture: one change to save", trialB)
  }
  // The fake hyprctl can't take an apply (the helper reverts it), so Save
  // is checked by the command it sends; the trial then comes through the
  // state file, as the helper's worker writes it (tests/qml/Runtime.qml).
  function trialB() {
    var b = button(view, view.tr("Save"))
    check(b !== null && b.kind === "primary", "Save is the primary button")
    if (!b)
      return finish()
    helperRuns = []
    pointerOnto(b)
    ev.mouseClick(b, b.width / 2, b.height / 2, Qt.LeftButton, Qt.NoModifier, -1)
    until(function () {
      return helperRuns.indexOf("apply") >= 0 && displayIdle()
    }, "a click on Save sends apply", trialC, 30000)
  }
  function trialC() {
    setPhase("testing", function () {
      until(function () {
        return service.testing && view.cursorKey === "revert" && displayIdle()
      }, "the trial", trialD)
    })
  }
  function trialD() {
    cursorChecks(view, view.tr("Keep settings"), "keep")
    var b = cursorChecks(view, view.tr("Revert"), "revert")
    if (!b)
      return finish()
    ev.mouseClick(b, b.width / 2, b.height / 2, Qt.LeftButton, Qt.NoModifier, -1)
    until(function () {
      return service.transaction.decision === "revert" && displayIdle()
    }, "a click on Revert sends revert", trialE)
  }
  function trialE() {
    setPhase("testing", function () {
      until(function () {
        return service.testing && service.transaction.decision !== "revert" && view.cursorKey === "revert" && displayIdle()
      }, "a second trial", trialF)
    })
  }
  function trialF() {
    var b = button(view, view.tr("Keep settings"))
    check(b !== null, "Keep settings: shown")
    if (!b)
      return finish()
    pointerOnto(b)
    eq(view.cursorKey, "keep", "Keep settings: the pointer entering takes the cursor")
    ev.mouseClick(b, b.width / 2, b.height / 2, Qt.LeftButton, Qt.NoModifier, -1)
    until(function () {
      return service.transaction.decision === "keep" && displayIdle()
    }, "a click on Keep settings sends keep", function () {
      setPhase("idle", finish)
    })
  }

  // The trial worker's phase change, written to the helper's state file
  // under its state.lock and replaced atomically, as the helper does; a
  // copy of tests/qml/Runtime.qml's setPhase ("testing" gets a stand-in
  // worker, "idle" ends it).
  function setPhase(phase, then) {
    var p = Qt.createQmlObject('import Quickshell.Io; Process {}', shell)
    p.exited.connect(function () {
      then()
    })
    p.command = ["python3", "-c", "import fcntl, json, os, signal, subprocess, sys, time\n" + "p, phase = sys.argv[1], sys.argv[2]\n" + "lock = open(os.path.join(os.path.dirname(p), 'state.lock'), 'a')\n" + "fcntl.flock(lock, fcntl.LOCK_EX)\n" + "s = json.load(open(p))\n" + "if s.get('workerPid'):\n" + "    try: os.kill(s['workerPid'], signal.SIGKILL)\n" + "    except OSError: pass\n" + "s.update(phase=phase, deadline=time.time() + 15 if phase != 'idle' else 0, token='buttons-trial', workerPid=0)\n" + "s.pop('decision', None)\n" + "if phase == 'testing':\n" + "    s['workerPid'] = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)', 'worker', '--token', 'buttons-trial'], start_new_session=True).pid\n" + "s['revision'] = s.get('revision', 0) + 1\n" + "with open(p + '.tmp', 'w') as out:\n" + "    json.dump(s, out)\n" + "os.replace(p + '.tmp', p)\n", service.statePath, phase]
    p.running = true
  }

  property bool finished: false
  function finish() {
    if (finished)
      return
    finished = true
    viewLoader.active = false
    console.log("FOAMY RESULT " + host + "/" + lang + " " + checks + " checks, " + failures + " failures")
    wait.after(1, function () {
      console.log("FOAMY DONE")
      Qt.quit()
    })
  }
}
