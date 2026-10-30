function clampBrightness(value) {
  var n = Number(value)
  if (!isFinite(n)) return 1
  return Math.max(1, Math.min(100, Math.round(n)))
}

// Laptop panels report a connector name in this family; their EDID make/model
// (e.g. "BOE 0x07DB") is a raw panel part number, never worth showing.
function isInternalConnector(name) {
  return /^(eDP|LVDS|DSI)-/i.test(String(name || ""))
}

function looksLikeRawCode(text) {
  var t = String(text || "").trim()
  if (!t) return true
  return /^0x[0-9a-f]+$/i.test(t)
}

function cleanVendorName(make) {
  var v = String(make || "").trim()
  v = v.replace(/\b(Electric Company|Electronics Co\.?,?\s*Ltd\.?|Technology Co\.?,?\s*Ltd\.?|Corporation|Incorporated|Inc\.?|Corp\.?|Co\.?,?\s*Ltd\.?)\b/gi, "")
  return v.replace(/[.,]+\s*$/, "").replace(/\s+/g, " ").trim()
}

// Builds a human name from hyprctl's make/model/description for one display,
// falling back through progressively less specific data down to the raw
// connector name (eDP-1, DP-7, ...).
function friendlyMonitorLabel(display) {
  if (!display) return ""
  var name = String(display.name || "")
  if (isInternalConnector(name)) return "Built-in display"

  var make = cleanVendorName(display.make || "")
  var model = String(display.model || "").trim()
  if (model && !looksLikeRawCode(model)) {
    return make && model.toLowerCase().indexOf(make.toLowerCase()) !== 0 ? make + " " + model : model
  }

  var description = String(display.description || "").trim()
  if (description) return description

  return name || "Unknown display"
}

// Full per-monitor info (position, mode, transform, ...) from
// `hyprctl monitors all -j`, plus the friendly label derived above.
// Returns { list, byName, labels } — list preserves hyprctl's own order.
// "3440x1440@165.00Hz" style tokens -> the distinct refresh rates (as
// numbers) available at exactly this width/height, highest first.
function refreshRatesFor(availableModes, width, height) {
  var w = Number(width), h = Number(height)
  var seen = {}
  var rates = []
  var list = Array.isArray(availableModes) ? availableModes : []
  for (var i = 0; i < list.length; i++) {
    var m = /^([0-9]+)x([0-9]+)@([0-9.]+)Hz$/.exec(String(list[i] || "").trim())
    if (!m) continue
    if (Number(m[1]) !== w || Number(m[2]) !== h) continue
    var rate = Number(m[3])
    if (!isFinite(rate) || seen[rate]) continue
    seen[rate] = true
    rates.push(rate)
  }
  rates.sort(function(a, b) { return b - a })
  return rates
}

function formatHz(rate) {
  var n = Number(rate)
  if (!isFinite(n)) return ""
  var rounded = Math.round(n * 100) / 100
  return (Number.isInteger(rounded) ? String(rounded) : rounded.toFixed(2)) + " Hz"
}

// Nearest of a set of numeric refresh rates to a live value (hyprctl reports
// e.g. 164.99899 for a mode advertised as 165.00).
function nearestRate(rates, current) {
  var list = Array.isArray(rates) ? rates : []
  if (list.length === 0) return NaN
  var best = list[0], bestDist = Infinity
  for (var i = 0; i < list.length; i++) {
    var d = Math.abs(list[i] - Number(current))
    if (d < bestDist) { bestDist = d; best = list[i] }
  }
  return best
}

// Enabled displays, left-to-right by current x position — the "order" the
// Arrangement section shows and reorders.
// Strict AABB overlap test: rects that only touch at an edge (a's right ==
// b's left) do not count as overlapping, so flush/snapped placement is
// never rejected as a collision.
function rectsOverlap(ax, ay, aw, ah, bx, by, bw, bh) {
  return ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by
}

// Nudges `target` ({x,y,w,h}, logical/layout pixels) out of `other` along
// whichever axis needs the smaller move, away from other's side. Used to
// fix up a monitor whose *footprint* just changed shape (a rotation swaps
// width/height) without its x/y moving, which can silently overlap a
// neighbor that was flush against it before.
function pushRectOutOf(target, other) {
  if (!rectsOverlap(target.x, target.y, target.w, target.h, other.x, other.y, other.w, other.h)) {
    return { x: target.x, y: target.y }
  }
  var penX = Math.min(target.x + target.w, other.x + other.w) - Math.max(target.x, other.x)
  var penY = Math.min(target.y + target.h, other.y + other.h) - Math.max(target.y, other.y)
  var x = target.x, y = target.y
  if (penX < penY) x += (target.x < other.x) ? -penX : penX
  else y += (target.y < other.y) ? -penY : penY
  return { x: x, y: y }
}

// Resolves `target` against every rect in `others`, a few passes since
// clearing one neighbor can graze another at these small monitor counts.
function resolveMonitorOverlap(target, others) {
  var x = target.x, y = target.y
  var w = target.w, h = target.h
  for (var pass = 0; pass < 4; pass++) {
    var moved = false
    for (var i = 0; i < others.length; i++) {
      var o = others[i]
      if (rectsOverlap(x, y, w, h, o.x, o.y, o.w, o.h)) {
        var pushed = pushRectOutOf({ x: x, y: y, w: w, h: h }, o)
        x = pushed.x
        y = pushed.y
        moved = true
      }
    }
    if (!moved) break
  }
  return { x: Math.round(x), y: Math.round(y) }
}

// Idle-timeout stops, seconds. Mirrors the curated feel of the text-size
// slider's px stops: a handful of sane, round choices rather than a raw
// continuous range.
function parseFluxCastScan(raw) {
  var payload = null
  try {
    payload = JSON.parse(String(raw || ""))
  } catch (e) {
    return { peers: [], error: "Could not read the FluxCast scan" }
  }

  if (!payload || payload.ok !== true) {
    return {
      peers: [],
      missingPackages: payload && Array.isArray(payload.missingPackages) ? payload.missingPackages : [],
      error: payload && payload.error ? String(payload.error) : "Wireless display scan failed"
    }
  }

  var sourcePeers = Array.isArray(payload.peers) ? payload.peers : []
  var peers = []
  for (var i = 0; i < sourcePeers.length; i++) {
    var peer = sourcePeers[i]
    var address = peer && peer.address ? String(peer.address).trim().toUpperCase() : ""
    if (!/^[0-9A-F]{2}(?::[0-9A-F]{2}){5}$/.test(address)) continue
    peers.push({
      address: address,
      name: peer.name ? String(peer.name).trim() : "",
      source: peer.source ? String(peer.source).trim() : "",
      wfdCapable: peer.wfdCapable === true
    })
  }

  return { peers: peers, error: "", missingPackages: [] }
}

function resolutionOptions(monitor) {
  if (!monitor) return []
  var seen = {}, result = []
  var modes = (monitor.availableModes || []).concat([monitor.width + "x" + monitor.height + "@0Hz"])
  modes.forEach(function(mode) {
    var match = /^(\d+)x(\d+)@/.exec(mode)
    if (!match) return
    var value = match[1] + "x" + match[2]
    if (seen[value]) return
    seen[value] = true
    result.push({value:value, label:match[1] + " × " + match[2]})
  })
  return result.sort(function(a,b) {
    var aa=a.value.split("x"), bb=b.value.split("x")
    return Number(bb[0])*Number(bb[1])-Number(aa[0])*Number(aa[1])
  })
}

function validScale(scale, width, height) {
  return scale >= 0.25 && scale <= 8 && [width,height].every(function(v) {
    return Math.abs(v/scale - Math.round(v/scale)) < 0.001
  })
}

function scaleOptions(monitor) {
  if (!monitor) return []
  var values = [1,1.25,4/3,1.5,1.6,1.75,2,2.5,3,4]
  if (!values.some(function(v) {return Math.abs(v-monitor.scale)<0.00001})) values.push(monitor.scale)
  return values.filter(function(v) {return validScale(v,monitor.width,monitor.height)})
    .sort(function(a,b) {return a-b})
    .map(function(v) {return {value:String(v),label:(Math.round(v*1000)/10)+"%"}})
}

function changedFields(base, draft) {
  if (!base || !draft) return []
  var groups = {resolution:["width","height"],rate:["refreshRate"],scale:["scale"],rotation:["transform"],position:["x","y"],enabled:["disabled"],mirror:["mirrorOf"]}
  return Object.keys(groups).filter(function(group) {
    return groups[group].some(function(key) {
      if (typeof base[key] === "number") return Math.abs(base[key]-draft[key]) > 0.00001
      return base[key] !== draft[key]
    })
  })
}

function footprint(monitor) {
  var w=Math.round(monitor.width/monitor.scale), h=Math.round(monitor.height/monitor.scale)
  return monitor.transform%2 ? {w:h,h:w} : {w:w,h:h}
}

function parseFluxCastEvent(raw) {
  var event = null
  try {
    event = JSON.parse(String(raw || ""))
  } catch (e) {
    return null
  }
  if (!event || (event.type !== "phase" && event.type !== "exit")) return null
  return event
}

// Hyprland events that change which outputs exist or how they are set up.
// Everything else (focus, workspaces, windows) leaves the display list alone.
var LAYOUT_EVENTS = ["monitoradded", "monitoraddedv2", "monitorremoved", "monitorremovedv2", "configreloaded"]

function isLayoutEvent(name) {
  return LAYOUT_EVENTS.indexOf(String(name || "")) !== -1
}

// The next DDC/backlight job. One job runs at a time for the whole shell, so
// a getvcp never overlaps a setvcp on any bus. Pending writes (latest value
// per display) go first once the slider settles; a read for a display with a
// pending write is dropped, since the written value is what it will read.
//   writes: { name: percent }, reads: [name], settling: debounce still running
function nextBrightnessJob(writes, reads, settling) {
  var names = Object.keys(writes || {})
  if (names.length && !settling)
    return { kind: "write", name: names[0], value: clampBrightness(writes[names[0]]) }
  var queue = reads || []
  for (var i = 0; i < queue.length; i++) {
    if (!writes || writes[queue[i]] === undefined)
      return { kind: "read", name: queue[i] }
  }
  return null
}

function parseBrightness(code, text) {
  var raw = String(text || "").trim()
  var value = Number(raw)
  if (code !== 0 || raw === "" || !isFinite(value)) return { available: false, percent: 0 }
  return { available: true, percent: clampBrightness(value) }
}

// Cursor stops for the main view, in reading order. Keys are stable strings
// so hover and keyboard share one cursor (FoamyCursor index into this list).
//   tab: "Display" | "Advanced" | "Wireless"; testing: a display trial is running
function viewStops(tab, testing, counts) {
  var c = counts || {}
  var list = []
  function add(prefix, n) { for (var i = 0; i < (n || 0); i++) list.push(prefix + i) }
  if (!testing) {
    list.push("tab:Display", "tab:Advanced", "tab:Wireless")
    if (tab === "Display") {
      add("box:", c.boxes)
      list.push("identify")
      add("offline:", c.offline)
      list.push("mode", "power", "resolution", "rate", "scale", "orientation", "brightness")
    } else if (tab === "Advanced") {
      list.push("textSize", "cursorSize", "gtkScale")
    } else {
      list.push("scan")
      add("peer:", c.peers)
    }
  }
  if (testing) list.push("revert", "keep")
  else if (c.changes > 0) list.push("discard", "save")
  if (!testing) list.push("settings")
  return list
}

if (typeof module !== "undefined") {
  module.exports = {
    resolutionOptions: resolutionOptions,
    validScale: validScale,
    scaleOptions: scaleOptions,
    changedFields: changedFields,
    footprint: footprint,
    parseFluxCastScan: parseFluxCastScan,
    parseFluxCastEvent: parseFluxCastEvent,
    clampBrightness: clampBrightness,
    isInternalConnector: isInternalConnector,
    friendlyMonitorLabel: friendlyMonitorLabel,
    refreshRatesFor: refreshRatesFor,
    formatHz: formatHz,
    nearestRate: nearestRate,
    rectsOverlap: rectsOverlap,
    pushRectOutOf: pushRectOutOf,
    resolveMonitorOverlap: resolveMonitorOverlap,
    isLayoutEvent: isLayoutEvent,
    nextBrightnessJob: nextBrightnessJob,
    parseBrightness: parseBrightness,
    viewStops: viewStops
  }
}
