function clampBrightness(value) {
  var n = Number(value)
  if (!isFinite(n)) return 1
  return Math.max(1, Math.min(100, Math.round(n)))
}

function normalizeScale(scale) {
  var n = parseFloat(String(scale || ""))
  if (!isFinite(n)) return ""
  return String(Math.round(n * 100) / 100)
}

function gcd(a, b) {
  while (b) {
    var remainder = a % b
    a = b
    b = remainder
  }
  return a
}

function cleanScale(scale, width, height) {
  var requested = Number(scale)
  var modeWidth = Number(width)
  var modeHeight = Number(height)
  if (!isFinite(requested) || !isFinite(modeWidth) || !isFinite(modeHeight)
      || requested <= 0 || modeWidth <= 0 || modeHeight <= 0) return ""

  var divisor = gcd(Math.round(modeWidth * 120), Math.round(modeHeight * 120))
  var scaleUnits = Math.round(requested * 120)
  if (scaleUnits > divisor) scaleUnits = divisor
  while (divisor % scaleUnits !== 0) scaleUnits++
  return normalizeScale(scaleUnits / 120)
}

function matchingScaleIndex(scales, currentScale, width, height) {
  var current = Number(currentScale)
  if (!Array.isArray(scales) || !isFinite(current)) return -1

  var bestIndex = -1
  var bestDistance = Infinity
  var normalizedCurrent = normalizeScale(current)
  for (var i = 0; i < scales.length; i++) {
    if (cleanScale(scales[i], width, height) !== normalizedCurrent) continue

    var distance = Math.abs(Number(scales[i]) - current)
    if (distance < bestDistance) {
      bestIndex = i
      bestDistance = distance
    }
  }
  return bestIndex
}

function availableScales(scales, width, height) {
  if (!Array.isArray(scales) || Number(width) <= 0 || Number(height) <= 0) return scales || []

  var byEffectiveScale = {}
  for (var i = 0; i < scales.length; i++) {
    var requested = Number(scales[i])
    var effective = Number(cleanScale(requested, width, height))

    if (!isFinite(requested) || !isFinite(effective)) continue

    var key = normalizeScale(effective)
    var existing = byEffectiveScale[key]
    if (!existing || Math.abs(requested - effective) < existing.distance) {
      byEffectiveScale[key] = {
        value: String(scales[i]),
        index: i,
        distance: Math.abs(requested - effective)
      }
    }
  }

  return Object.keys(byEffectiveScale)
    .map(function(key) { return byEffectiveScale[key] })
    .sort(function(a, b) { return a.index - b.index })
    .map(function(candidate) { return candidate.value })
}

function brightnessName(percent) {
  var p = Math.round(percent)
  if (p >= 95) return "Sun blast"
  if (p >= 80) return "Solar flare"
  if (p >= 65) return "Golden hour"
  if (p >= 45) return "Even day"
  if (p >= 30) return "Soft glow"
  if (p >= 20) return "Lamp light"
  if (p >= 10) return "Candlelit"
  return "Night owl"
}

function parseDisplays(raw) {
  var displays = []
  try {
    displays = raw ? JSON.parse(String(raw)) : []
  } catch (e) {
    displays = []
  }
  if (!Array.isArray(displays)) displays = []

  var count = 0
  for (var i = 0; i < displays.length; i++) {
    if (displays[i] && displays[i].enabled) count++
  }

  return {
    displays: displays,
    enabledDisplayCount: count
  }
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

function parseMonitorLabels(raw) {
  var list = []
  try {
    list = raw ? JSON.parse(String(raw)) : []
  } catch (e) {
    list = []
  }
  if (!Array.isArray(list)) list = []

  var map = {}
  for (var i = 0; i < list.length; i++) {
    var m = list[i]
    if (!m || !m.name) continue
    map[m.name] = friendlyMonitorLabel(m)
  }
  return map
}

// Full per-monitor info (position, mode, transform, ...) from
// `hyprctl monitors all -j`, plus the friendly label derived above.
// Returns { list, byName, labels } — list preserves hyprctl's own order.
function parseMonitorInfo(raw) {
  var list = []
  try {
    list = raw ? JSON.parse(String(raw)) : []
  } catch (e) {
    list = []
  }
  if (!Array.isArray(list)) list = []

  var byName = {}
  var labels = {}
  var out = []
  for (var i = 0; i < list.length; i++) {
    var m = list[i]
    if (!m || !m.name) continue
    var label = friendlyMonitorLabel(m)
    var entry = {
      name: m.name,
      x: Number(m.x) || 0,
      y: Number(m.y) || 0,
      width: Number(m.width) || 0,
      height: Number(m.height) || 0,
      refreshRate: Number(m.refreshRate) || 0,
      scale: Number(m.scale) || 1,
      transform: Number(m.transform) || 0,
      disabled: !!m.disabled,
      focused: !!m.focused,
      availableModes: Array.isArray(m.availableModes) ? m.availableModes : [],
      label: label
    }
    out.push(entry)
    byName[entry.name] = entry
    labels[entry.name] = label
  }
  return { list: out, byName: byName, labels: labels }
}

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
function orderedEnabledMonitors(monitorList) {
  var list = Array.isArray(monitorList) ? monitorList : []
  var enabled = []
  for (var i = 0; i < list.length; i++) if (list[i] && !list[i].disabled) enabled.push(list[i])
  enabled.sort(function(a, b) { return a.x - b.x })
  return enabled
}

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
function nearestStopIndex(stops, seconds) {
  var best = 0
  var bestDist = Infinity
  var n = Number(seconds)
  for (var i = 0; i < stops.length; i++) {
    var d = Math.abs(stops[i] - n)
    if (d < bestDist) { bestDist = d; best = i }
  }
  return best
}

function formatDuration(seconds) {
  var s = Math.max(0, Math.round(Number(seconds) || 0))
  if (s < 60) return s + "s"
  var m = Math.floor(s / 60)
  var rem = s % 60
  return rem === 0 ? (m + "m") : (m + "m " + rem + "s")
}

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
    normalizeScale: normalizeScale,
    cleanScale: cleanScale,
    matchingScaleIndex: matchingScaleIndex,
    availableScales: availableScales,
    brightnessName: brightnessName,
    parseDisplays: parseDisplays,
    isInternalConnector: isInternalConnector,
    friendlyMonitorLabel: friendlyMonitorLabel,
    parseMonitorLabels: parseMonitorLabels,
    nearestStopIndex: nearestStopIndex,
    formatDuration: formatDuration,
    parseMonitorInfo: parseMonitorInfo,
    refreshRatesFor: refreshRatesFor,
    formatHz: formatHz,
    nearestRate: nearestRate,
    orderedEnabledMonitors: orderedEnabledMonitors,
    rectsOverlap: rectsOverlap,
    pushRectOutOf: pushRectOutOf,
    resolveMonitorOverlap: resolveMonitorOverlap
  }
}
