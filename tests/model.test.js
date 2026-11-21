const assert = require("node:assert/strict")
const { test } = require("node:test")
const Model = require("../Model.js")

test("a scan reply becomes clean receivers", () => {
  assert.deepEqual(Model.parseFluxCastScan(JSON.stringify({
    ok: true,
    peers: [
      {
        address: "7a:2d:91:40:0b:ce",
        name: " Living Room TV ",
        source: "NetworkManager",
        wfdCapable: true
      },
      { address: "not-a-mac", name: "Ignore me" }
    ]
  })), {
    peers: [{
      address: "7A:2D:91:40:0B:CE",
      name: "Living Room TV",
      source: "NetworkManager",
      wfdCapable: true
    }],
    error: "",
    missingPackages: []
  })
})

test("unreadable scan output is an error", () => {
  assert.deepEqual(Model.parseFluxCastScan('{'), {
    peers: [],
    error: "Could not read the FluxCast scan"
  })
})

test("a failed scan keeps its error and missing packages", () => {
  assert.deepEqual(Model.parseFluxCastScan(JSON.stringify({
    ok: false,
    error: "No P2P interface",
    peers: []
  })), {
    peers: [],
    error: "No P2P interface",
    missingPackages: []
  })
  assert.deepEqual(Model.parseFluxCastScan('{"ok":false,"error":"Please install fluxcast-git","missingPackages":["fluxcast-git"]}').missingPackages, ["fluxcast-git"])
})

test("an empty scan", () => {
  assert.deepEqual(Model.parseFluxCastScan('{"ok":true,"peers":[]}'), {peers: [], error: "", missingPackages: []})
})

test("cast lines other than phase and exit events are ignored", () => {
  assert.deepEqual(Model.parseFluxCastEvent('{"type":"phase","phase":"casting"}'), {
    type: "phase",
    phase: "casting"
  })
  assert.equal(Model.parseFluxCastEvent("not json"), null)
  assert.equal(Model.parseFluxCastEvent('{"type":"log"}'), null)
})

test("refresh rates of the chosen resolution, highest first, with their labels", () => {
  // Advertised modes can repeat rates across resolutions; keep only this mode.
  assert.deepEqual(Model.refreshRatesFor([
    "5120x2160@120.00Hz", "5120x2160@59.94Hz", "5120x2160@120.00Hz",
    "1920x1080@144.00Hz", "invalid"
  ], 5120, 2160), [120, 59.94])
  assert.equal(Model.nearestRate([120, 59.94], 119.999), 120)
  // What the refresh rate dropdown shows.
  assert.equal(Model.formatHz(60), "60 Hz")
  assert.equal(Model.formatHz(59.94), "59.94 Hz")
  assert.equal(Model.formatHz(143.998), "144 Hz")
  assert.equal(Model.formatHz("x"), "")
})

test("friendly display names", () => {
  for (const [display, label] of [
    [{name: "eDP-1", make: "BOE", model: "0x1234"}, "Built-in display"],
    [{name: "DP-1", make: "Dell Inc.", model: "DELL U4025QW"}, "DELL U4025QW"],
    [{name: "DP-2", make: "Samsung Electric Company", model: "Odyssey G9"}, "Samsung Odyssey G9"],
    // A raw model code is skipped for the description.
    [{name: "DP-3", make: "BNQ", model: "0x7F12", description: "BenQ EW3270U"}, "BenQ EW3270U"],
    [{name: "HDMI-A-1"}, "HDMI-A-1"],
    [null, ""],
  ])
    assert.equal(Model.friendlyMonitorLabel(display), label, JSON.stringify(display))
})

test("a dragged display that touches another stays; an overlap moves by the smaller push", () => {
  const other = [{x: 0, y: 0, w: 100, h: 100}]
  assert.deepEqual(Model.resolveMonitorOverlap({x: 100, y: 0, w: 100, h: 100}, other), {x: 100, y: 0})
  assert.deepEqual(Model.resolveMonitorOverlap({x: 90, y: 0, w: 100, h: 100}, other), {x: 100, y: 0})
  assert.deepEqual(Model.resolveMonitorOverlap({x: 10, y: 90, w: 100, h: 100}, other), {x: 10, y: 100})
})

test("scale choices give whole logical pixels", () => {
  const dell = {width:5120,height:2160,scale:1.3333334,refreshRate:120,transform:0,x:0,y:0,disabled:false,mirrorOf:"",availableModes:["5120x2160@60.00Hz","5120x2160@120.00Hz","3840x2160@60.00Hz"]}
  assert.equal(Model.validScale(1.4, 5120, 2160), false)
  assert.deepEqual(Model.scaleOptions(dell).map(o => o.label),
    ["100%", "125%", "133.3%", "160%", "200%", "250%", "400%"])
  // A current scale outside the list is offered too.
  assert.deepEqual(Model.scaleOptions({width: 1920, height: 1080, scale: 1.2}).map(o => o.label),
    ["100%", "120%", "125%", "133.3%", "150%", "160%", "200%", "250%", "300%", "400%"])
})

test("resolutions are distinct, largest first", () => {
  const dell = {width:5120,height:2160,availableModes:["5120x2160@60.00Hz","5120x2160@120.00Hz","3840x2160@60.00Hz"]}
  assert.deepEqual(Model.resolutionOptions(dell).map(v=>v.value),["5120x2160","3840x2160"])
})

test("changed groups and the rotated footprint", () => {
  const dell = {width:5120,height:2160,scale:1.3333334,refreshRate:120,transform:0,x:0,y:0,disabled:false,mirrorOf:""}
  assert.deepEqual(Model.changedFields(dell,{...dell,scale:1.25,x:100,y:100}),["scale","position"])
  assert.deepEqual(Model.footprint({...dell,transform:1}),{w:1620,h:3840})
})

test("only output-layout events wake the status helper", () => {
  for (const name of ["monitoradded", "monitoraddedv2", "monitorremoved", "monitorremovedv2", "configreloaded"])
    assert.equal(Model.isLayoutEvent(name), true, name)
  for (const name of ["focusedmon", "workspace", "activewindow", "", undefined])
    assert.equal(Model.isLayoutEvent(name), false, String(name))
})

test("one brightness job at a time, writes first", () => {
  // DDC access is serialised: writes wait for the slider to settle, then go
  // before reads, and a read for a display with a pending write is dropped.
  assert.equal(Model.nextBrightnessJob({}, [], false), null)
  assert.deepEqual(Model.nextBrightnessJob({ "DP-1": 40 }, ["DP-1"], true), null)
  assert.deepEqual(Model.nextBrightnessJob({ "DP-1": 40 }, ["DP-1", "DP-2"], true), { kind: "read", name: "DP-2" })
  assert.deepEqual(Model.nextBrightnessJob({ "DP-1": 140 }, ["DP-2"], false), { kind: "write", name: "DP-1", value: 100 })
  assert.deepEqual(Model.nextBrightnessJob({}, ["DP-2"], false), { kind: "read", name: "DP-2" })
  assert.deepEqual(Model.parseBrightness(0, " 42\n"), { available: true, percent: 42 })
  assert.deepEqual(Model.parseBrightness(0, ""), { available: false, percent: 0 })
  assert.deepEqual(Model.parseBrightness(1, "42"), { available: false, percent: 0 })
})

test("cursor stops in reading order, no Settings stop; a trial has only Revert and Keep", () => {
  assert.deepEqual(Model.viewStops("Advanced", false, { changes: 0 }),
    ["tab:Display", "tab:Advanced", "tab:Wireless", "textSize", "cursorSize", "gtkScale"])
  assert.deepEqual(Model.viewStops("Display", false, { boxes: 2, offline: 1, changes: 1 }),
    ["tab:Display", "tab:Advanced", "tab:Wireless", "box:0", "box:1", "identify", "offline:0", "mode", "power",
      "resolution", "rate", "scale", "orientation", "brightness", "discard", "save"])
  assert.deepEqual(Model.viewStops("Wireless", false, { peers: 2 }),
    ["tab:Display", "tab:Advanced", "tab:Wireless", "scan", "peer:0", "peer:1"])
  assert.deepEqual(Model.viewStops("Display", true, { boxes: 2, changes: 3 }), ["revert", "keep"])
})

test("a cached brightness is reused only within a wheel burst", () => {
  assert.equal(Model.brightnessFresh({ available: true, percent: 50, at: 1000 }, 2500), true)
  assert.equal(Model.brightnessFresh({ available: true, percent: 50, at: 1000 }, 3001), false)
  assert.equal(Model.brightnessFresh({ available: true, percent: 50 }, 1000), false)
  assert.equal(Model.brightnessFresh(null, 1000), false)
})

test("brightness changes queued behind a read merge", () => {
  // An explicit level keeps later steps relative to it.
  assert.deepEqual(Model.mergeBrightnessChange(null, { delta: 5 }), { delta: 5 })
  assert.deepEqual(Model.mergeBrightnessChange({ delta: 5 }, { delta: -10 }), { delta: -5 })
  assert.deepEqual(Model.mergeBrightnessChange({ value: 40 }, { delta: 5 }), { value: 45 })
  assert.deepEqual(Model.mergeBrightnessChange({ delta: 5 }, { value: 40 }), { value: 40 })
  assert.deepEqual(Model.mergeBrightnessChange({ value: 40 }, { value: 70 }), { value: 70 })
})

test("the receiver list on reopen: kept, refreshed silently, or discarded", () => {
  // A 2-minute cache; no refresh right after a scan; a stale or
  // future-dated scan is discarded.
  for (const [scannedAt, now, action] of [
    [0, 5000, "discard"],
    [1000, 6000, "keep"],
    [1000, 11000, "refresh"],
    [1000, 120000, "refresh"],
    [1000, 121000, "refresh"],
    [1000, 121001, "discard"],
    [5000, 4000, "discard"],
  ])
    assert.equal(Model.wirelessOpenAction(scannedAt, now), action, `scanned ${scannedAt}, now ${now}`)
})

test("a finished scan merges into the list on screen", () => {
  // Stable order, fresh details, new receivers last, missing ones dropped,
  // duplicates collapsed.
  const tv = { address: "7A:2D:91:40:0B:CE", name: "Living Room TV" }
  const box = { address: "02:11:22:33:44:55", name: "" }
  const den = { address: "0A:0B:0C:0D:0E:0F", name: "Den" }
  assert.deepEqual(Model.mergeWirelessPeers([], [box, tv]), [box, tv])
  assert.deepEqual(Model.mergeWirelessPeers([tv, box], [box, tv]), [tv, box], "order stays as shown")
  assert.deepEqual(Model.mergeWirelessPeers([tv, box], [den, box]), [box, den], "gone dropped, new appended")
  const renamed = { address: box.address, name: "Projector" }
  assert.deepEqual(Model.mergeWirelessPeers([tv, box], [renamed, tv]), [tv, renamed], "fresh details win")
  assert.deepEqual(Model.mergeWirelessPeers([tv], [den, den, tv]), [tv, den], "duplicates collapse")
  assert.deepEqual(Model.mergeWirelessPeers([tv, box], []), [], "an empty scan empties the list")
})
