const assert = require("node:assert/strict")
const Model = require("../Model.js")

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

assert.deepEqual(Model.parseFluxCastScan('{'), {
  peers: [],
  error: "Could not read the FluxCast scan"
})

assert.deepEqual(Model.parseFluxCastScan(JSON.stringify({
  ok: false,
  error: "No P2P interface",
  peers: []
})), {
  peers: [],
  error: "No P2P interface",
  missingPackages: []
})

assert.deepEqual(Model.parseFluxCastEvent('{"type":"phase","phase":"casting"}'), {
  type: "phase",
  phase: "casting"
})
assert.equal(Model.parseFluxCastEvent("not json"), null)
assert.equal(Model.parseFluxCastEvent('{"type":"log"}'), null)

console.log("monitor model tests passed")

// Advertised modes can repeat rates across resolutions; keep only this mode.
assert.deepEqual(Model.refreshRatesFor([
  "5120x2160@120.00Hz", "5120x2160@59.94Hz", "5120x2160@120.00Hz",
  "1920x1080@144.00Hz", "invalid"
], 5120, 2160), [120, 59.94])
assert.equal(Model.nearestRate([120, 59.94], 119.999), 120)
assert.equal(Model.friendlyMonitorLabel({name: "eDP-1", make: "BOE", model: "0x1234"}), "Built-in display")
assert.equal(Model.rectsOverlap(0, 0, 100, 100, 100, 0, 100, 100), false)
const moved = Model.resolveMonitorOverlap({x: 90, y: 0, w: 100, h: 100}, [{x: 0, y: 0, w: 100, h: 100}])
assert.deepEqual(moved, {x: 100, y: 0})
assert.equal(Model.rectsOverlap(moved.x, moved.y, 100, 100, 0, 0, 100, 100), false)
assert.deepEqual(Model.parseFluxCastScan('{"ok":true,"peers":[]}'), {peers: [], error: "", missingPackages: []})
console.log("monitor extender model tests passed")

const dell = {width:5120,height:2160,scale:1.3333334,refreshRate:120,transform:0,x:0,y:0,disabled:false,mirrorOf:"",availableModes:["5120x2160@60.00Hz","5120x2160@120.00Hz","3840x2160@60.00Hz"]}
assert.equal(Model.friendlyMonitorLabel({name:"DP-1",make:"Dell Inc.",model:"DELL U4025QW"}), "DELL U4025QW")
assert.equal(Model.validScale(1.4,5120,2160),false)
assert.ok(Model.scaleOptions(dell).some(option=>Math.abs(Number(option.value)-4/3)<0.00001))
assert.ok(Model.scaleOptions(dell).every(option=>Model.validScale(Number(option.value),5120,2160)))
assert.deepEqual(Model.resolutionOptions(dell).map(v=>v.value),["5120x2160","3840x2160"])
assert.deepEqual(Model.changedFields(dell,{...dell,scale:1.25,x:100,y:100}),["scale","position"])
assert.deepEqual(Model.footprint({...dell,transform:1}),{w:1620,h:3840})
assert.deepEqual(Model.parseFluxCastScan('{"ok":false,"error":"Please install fluxcast-git","missingPackages":["fluxcast-git"]}').missingPackages,["fluxcast-git"])

// Only output-layout events wake the status helper.
for (const name of ["monitoradded", "monitoraddedv2", "monitorremoved", "monitorremovedv2", "configreloaded"])
  assert.equal(Model.isLayoutEvent(name), true, name)
for (const name of ["focusedmon", "workspace", "activewindow", "", undefined])
  assert.equal(Model.isLayoutEvent(name), false, String(name))

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

// One cursor list per view; the trial footer replaces everything else.
assert.deepEqual(Model.viewStops("Advanced", false, { changes: 0 }),
  ["tab:Display", "tab:Advanced", "tab:Wireless", "textSize", "cursorSize", "gtkScale", "settings"])
assert.deepEqual(Model.viewStops("Display", false, { boxes: 2, offline: 1, changes: 1 }),
  ["tab:Display", "tab:Advanced", "tab:Wireless", "box:0", "box:1", "identify", "offline:0", "mode", "power",
    "resolution", "rate", "scale", "orientation", "brightness", "discard", "save", "settings"])
assert.deepEqual(Model.viewStops("Wireless", false, { peers: 2 }),
  ["tab:Display", "tab:Advanced", "tab:Wireless", "scan", "peer:0", "peer:1", "settings"])
assert.deepEqual(Model.viewStops("Display", true, { boxes: 2, changes: 3 }), ["revert", "keep"])

// A cached brightness is reused only within a wheel burst.
assert.equal(Model.brightnessFresh({ available: true, percent: 50, at: 1000 }, 2500), true)
assert.equal(Model.brightnessFresh({ available: true, percent: 50, at: 1000 }, 3001), false)
assert.equal(Model.brightnessFresh({ available: true, percent: 50 }, 1000), false)
assert.equal(Model.brightnessFresh(null, 1000), false)

// Changes queued behind a read: an explicit level keeps later steps relative to it.
assert.deepEqual(Model.mergeBrightnessChange(null, { delta: 5 }), { delta: 5 })
assert.deepEqual(Model.mergeBrightnessChange({ delta: 5 }, { delta: -10 }), { delta: -5 })
assert.deepEqual(Model.mergeBrightnessChange({ value: 40 }, { delta: 5 }), { value: 45 })
assert.deepEqual(Model.mergeBrightnessChange({ delta: 5 }, { value: 40 }), { value: 40 })
assert.deepEqual(Model.mergeBrightnessChange({ value: 40 }, { value: 70 }), { value: 70 })
