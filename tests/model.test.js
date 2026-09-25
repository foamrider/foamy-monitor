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
assert.deepEqual(Model.parseMonitorInfo("{"), { list: [], byName: {}, labels: {} })
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
