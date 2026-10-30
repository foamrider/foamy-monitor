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
      // A scan that is still running when the plugin goes away.
      shell.service.wirelessWanted = true
      shell.service.startWirelessScan()
      stepSeven.start()
    }
  }

  Timer {
    id: stepSeven
    interval: 1200
    onTriggered: {
      eq(shell.service.scanRunning, true, "scan started")
      eq(shell.service.brightness["DP-1"].percent, 45, "40 then +5 lands on 45, not the hardware level + 5")
      eq(shell.service.brightness["eDP-1"].percent, 40, "the explicit level stays after the read lands")
      eq(shell.service.brightnessAfterRead["eDP-1"], undefined, "no stale step left behind")
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
      shell.finish()
    }
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
