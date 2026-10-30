pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import qs.Ui as Ui
import "kit"
import "Model.js" as Model

// The popup body: header, Display / Advanced / Wireless tabs, the trial
// footer and the settings page. Shared data comes from MonitorService; the
// host (Panel.qml, or a mock in preview/Preview.qml) provides `bar`,
// `opened`, `editingSettings`, close(), openSettings(), closeSettings() and
// switchPanel(direction).
//
// Keyboard (one cursor, hover moves it too): j/k or arrows walk the stops,
// h/l switch tabs and step brightness, Enter activates (opens a dropdown),
// m moves the display under the cursor with the arrows (Enter/Esc to drop),
// w opens Wireless, s Settings, r refreshes, Ctrl+S saves, Tab/Shift+Tab go
// to the next bar panel, Esc reverts a running trial or closes.
PanelKeyCatcher {
  id: view

  required property var host
  readonly property bool editing: host.editingSettings === true

  property string selectedMonitor: ""
  property string activeTab: "Display"
  property int openDropdowns: 0
  property string moving: ""
  property real now: Date.now()

  readonly property var transaction: MonitorService.transaction
  readonly property bool busy: MonitorService.busy
  readonly property bool testing: MonitorService.testing
  readonly property int changeCount: MonitorService.changeCount
  readonly property string actionError: MonitorService.error || transaction.error || ""
  readonly property int secondsLeft: Math.min(15, Math.max(0, Math.ceil(((transaction.deadline || 0) * 1000 - now) / 1000)))
  readonly property var selected: transaction.draft.find(function(m) { return m.id === view.selectedMonitor }) || null
  readonly property var selectedLive: MonitorService.liveMonitors.find(function(m) { return m.id === view.selectedMonitor }) || null
  readonly property var enabledMonitorInfos: transaction.draft.filter(function(m) { return m.connected && !m.disabled && !m.mirrorOf })
  readonly property var offlineMonitors: transaction.draft.filter(function(m) { return m.disabled || !m.connected || !!m.mirrorOf })
  readonly property int activeCount: transaction.draft.filter(function(m) { return m.connected && !m.disabled }).length
  readonly property string brightnessTarget: selectedLive && !selectedLive.disabled ? selectedLive.name : ""
  readonly property var brightnessState: brightnessTarget ? MonitorService.brightness[brightnessTarget] || null : null
  readonly property bool brightnessAvailable: !!brightnessState && brightnessState.available
  readonly property int brightnessPercent: brightnessState ? brightnessState.percent : 0
  readonly property color changedColor: FoamyPalette.onSurface(FoamyPalette.warning)
  readonly property var gtkScale: MonitorService.gtkScale

  readonly property var tabs: ["Display", "Advanced", "Wireless"]
  readonly property var stops: Model.viewStops(activeTab, testing, {
    boxes: enabledMonitorInfos.length, offline: offlineMonitors.length,
    peers: MonitorService.castRunning || MonitorService.scanRunning ? 0 : MonitorService.wirelessPeers.length,
    changes: busy ? 0 : changeCount
  })
  readonly property string cursorKey: cursor.index >= 0 && cursor.index < stops.length ? stops[cursor.index] : ""
  function hasCursor(key) { return cursorKey === key }
  function hover(key) { var index = stops.indexOf(key); if (index >= 0) cursor.hover(index) }
  function place(key) { var index = stops.indexOf(key); if (index >= 0) cursor.index = index }
  function stopIndex(prefix) { return cursorKey.indexOf(prefix) === 0 ? Number(cursorKey.slice(prefix.length)) : -1 }

  FoamyCursor { id: cursor; count: view.stops.length }

  // Deferred work owned by this view: Qt.callLater would still run after the
  // view is destroyed (its bar removed on unplug); a child Timer dies with it.
  property var _deferred: []
  function defer(fn) { _deferred.push(fn); deferTimer.restart() }
  Timer {
    id: deferTimer
    interval: 0
    onTriggered: {
      var pending = view._deferred
      view._deferred = []
      for (var i = 0; i < pending.length; i++) pending[i]()
    }
  }

  implicitWidth: FoamyStyle.popupWidthWide
  implicitHeight: editing ? settingsPage.implicitHeight : header.height + tabBar.height + content.implicitHeight + footer.height
  blocked: editing || openDropdowns > 0

  // ---- Strings ------------------------------------------------------------
  function tr(text, values) {
    // Helpers return English recovery messages plus opaque package/monitor details.
    // Translate only known prefixes; never interpret or translate the detail itself.
    if (values === undefined) {
      var prefixes = ["Please install ", "Could not read display settings: ",
        "Unsupported scale for ", "Unsupported resolution or refresh rate for "]
      for (var i = 0; i < prefixes.length; i++) {
        if (String(text).indexOf(prefixes[i]) === 0)
          return FoamyI18n.t(prefixes[i] + "%1", String(text).slice(prefixes[i].length))
      }
    }
    return FoamyI18n.t(text, values)
  }
  function friendlyDisplayName(monitor) { return tr(Model.friendlyMonitorLabel(monitor)) }
  function peerLabel(peer) { return peer.name || tr("Wireless display") }
  function wirelessPhaseLabel() {
    var phase = MonitorService.castPhase
    if (phase === "casting") return tr("Casting to %1", MonitorService.castTargetName)
    if (phase === "stopping") return tr("Stopping…")
    if (phase === "error") return MonitorService.castDetail
    return tr("Connecting to %1…", MonitorService.castTargetName)
  }
  readonly property var rotationOptions: [
    { value: "0", label: "Landscape · 0°" }, { value: "1", label: "Portrait · 90°" },
    { value: "2", label: "Landscape · 180°" }, { value: "3", label: "Portrait · 270°" },
    { value: "4", label: "Flipped · 0°" }, { value: "5", label: "Flipped · 90°" },
    { value: "6", label: "Flipped · 180°" }, { value: "7", label: "Flipped · 270°" }
  ]
  readonly property var gtkScaleOptions: [1, 2, 3, 4].concat(gtkScale.value > 4 ? [gtkScale.value] : []).map(function(v) {
    return { value: String(v), label: FoamyI18n.t("%1%", v * 100) }
  })
  function pxOptions(values) { return values.map(function(v) { return { value: v, label: FoamyI18n.t("%1 px", Number(v)) } }) }
  readonly property var rateOptions: selected ? Model.refreshRatesFor(selected.availableModes, selected.width, selected.height).map(function(v) {
    return { value: String(v), label: Model.formatHz(v) }
  }) : []
  readonly property var scaleOptions: selected ? Model.scaleOptions(selected) : []
  readonly property string scaleValue: {
    if (!selected) return ""
    var option = scaleOptions.find(function(v) { return Math.abs(Number(v.value) - view.selected.scale) < 0.00001 })
    return option ? option.value : String(selected.scale)
  }
  readonly property var mirrorOptions: [{ value: "", label: tr("Extend") }].concat(transaction.draft.filter(function(m) {
    return m.connected && !m.disabled && !m.mirrorOf && m.id !== view.selectedMonitor
  }).map(function(m) { return { value: m.name, label: view.tr("Mirror %1", view.friendlyDisplayName(m)) } }))

  // ---- Actions ------------------------------------------------------------
  function marked(field) { return selected && MonitorService.changesFor(selected).indexOf(field) >= 0 }
  function selectMonitor(id) {
    selectedMonitor = id
    defer(refreshBrightness)
  }
  function refreshBrightness() { if (brightnessTarget && host.opened) MonitorService.readBrightness(brightnessTarget) }
  function edit(changes, monitor) {
    monitor = monitor || selected
    if (!monitor || busy) return
    MonitorService.enqueue("patch", { id: monitor.id, changes: changes })
  }
  function setResolution(value) {
    var size = value.split("x").map(Number)
    var rates = Model.refreshRatesFor(selected.availableModes, size[0], size[1])
    var scale = Model.validScale(selected.scale, size[0], size[1]) ? selected.scale : 1
    edit({ width: size[0], height: size[1], refreshRate: Model.nearestRate(rates, selected.refreshRate), scale: scale })
  }
  function rightEdge(exclude) {
    return enabledMonitorInfos.filter(function(m) { return m.id !== exclude }).reduce(function(x, m) {
      return Math.max(x, m.x + Model.footprint(m).w)
    }, 0)
  }
  function toggleDisplay() {
    if (!selected || !selected.connected || (!selected.disabled && activeCount <= 1)) return
    var values = { disabled: !selected.disabled, mirrorOf: "" }
    if (selected.disabled) { values.x = rightEdge(""); values.y = 0 }
    edit(values)
  }
  function setMirror(value) {
    if (!selected) return
    var values = { mirrorOf: value }
    if (!value) { values.x = rightEdge(selectedMonitor); values.y = 0 }
    edit(values)
  }
  function moveMonitor(name, x, y) {
    var monitor = transaction.draft.find(function(m) { return m.name === name })
    if (monitor) edit({ x: Math.round(x), y: Math.round(y) }, monitor)
  }
  function save() {
    if (changeCount && !busy && !MonitorService.disconnectedDraft) MonitorService.enqueue("apply")
  }
  function decide(action) { MonitorService.enqueue(action, { token: transaction.token }) }
  function scanOrStop() {
    if (MonitorService.castRunning) MonitorService.stopCast()
    else MonitorService.checkWireless(true)
  }
  function connectPeer(peer) {
    var monitor = selectedLive && !selectedLive.disabled ? selectedLive.name : MonitorService.focusedMonitor
    MonitorService.connectWirelessPeer(peer, peerLabel(peer), monitor)
  }
  function setTab(tab) {
    if (tabs.indexOf(tab) < 0) return
    activeTab = tab
  }
  // Requests this view makes of the shared service, as demand that ends with
  // the view: Wireless shown (scan + dependency retries) and a drag in
  // progress (holds status results until the drop).
  property bool dragging: false
  FoamyMember { id: wirelessDemand; scope: "monitor-wireless"; demanding: view.host.opened === true && view.activeTab === "Wireless" }
  FoamyMember { id: dragDemand; scope: "monitor-drag"; demanding: view.dragging }
  function dropdownFor(key) {
    return ({ mode: modeField, resolution: resolutionField, rate: rateField, scale: scaleField, orientation: orientationField,
      textSize: textSizeField, cursorSize: cursorSizeField, gtkScale: gtkScaleField })[key] || null
  }
  function boxName(i) { var box = diagram.boxes[i]; return box ? box.name : "" }
  function activateStop() {
    var key = cursorKey
    var field = dropdownFor(key)
    if (field) { if (field.enabled) field.open(); return }
    if (key.indexOf("tab:") === 0) setTab(key.slice(4))
    else if (key.indexOf("box:") === 0) { var monitor = transaction.draft.find(function(m) { return m.name === view.boxName(view.stopIndex("box:")) }); if (monitor) selectMonitor(monitor.id) }
    else if (key.indexOf("offline:") === 0) { var off = offlineMonitors[stopIndex("offline:")]; if (off) selectMonitor(off.id) }
    else if (key.indexOf("peer:") === 0) connectPeer(MonitorService.wirelessPeers[stopIndex("peer:")])
    else if (key === "identify") MonitorService.showIdentify()
    else if (key === "power") toggleDisplay()
    else if (key === "scan") scanOrStop()
    else if (key === "discard") MonitorService.enqueue("discard")
    else if (key === "save") save()
    else if (key === "revert") decide("revert")
    else if (key === "keep") decide("keep")
    else if (key === "settings") host.openSettings()
  }
  function stepBrightness(direction) {
    if (brightnessAvailable) MonitorService.setBrightness(brightnessTarget, brightnessPercent + direction * 5)
  }
  // Key repeat outruns the patch helper, so nudges add up on an optimistic
  // position instead of re-reading a draft that has not caught up yet.
  property var movingAt: null
  onMovingChanged: {
    var monitor = transaction.draft.find(function(m) { return m.name === view.moving })
    movingAt = monitor ? { x: monitor.x, y: monitor.y } : null
  }
  function nudge(dx, dy) {
    if (!movingAt) { moving = ""; return }
    movingAt = { x: movingAt.x + dx * 10, y: movingAt.y + dy * 10 }
    moveMonitor(moving, movingAt.x, movingAt.y)
  }

  onMoveRequested: function(dx, dy) {
    if (moving) { nudge(dx, dy); return }
    var key = cursorKey
    // The tabs are one row: j leaves it into the tab's content, k from the
    // content returns to the active tab.
    if (dy > 0 && key.indexOf("tab:") === 0) { cursor.index = Math.min(stops.length - 1, stops.indexOf("tab:Wireless") + 1); return }
    if (dy < 0 && cursor.index > 0 && stops[cursor.index - 1].indexOf("tab:") === 0) { place("tab:" + activeTab); return }
    if (dy !== 0) { cursor.move(dy); return }
    if (key === "brightness") stepBrightness(dx)
    else if (key.indexOf("tab:") === 0) {
      var next = tabs[Math.max(0, Math.min(tabs.length - 1, tabs.indexOf(key.slice(4)) + dx))]
      setTab(next)
      place("tab:" + next)
    } else cursor.move(dx)
  }
  onActivateRequested: { if (moving) moving = ""; else activateStop() }
  onCloseRequested: {
    if (moving) moving = ""
    else if (testing) decide("revert")
    else host.close()
  }
  onTabRequested: function(direction) { host.switchPanel(direction) }
  onTextKey: function(text, modifiers) {
    if (testing) return
    if (text === "\u0013" || ((modifiers & Qt.ControlModifier) && (text === "s" || text === "S"))) { save(); return }
    if (!cursor.plain(modifiers)) return
    if (text === "s") host.openSettings()
    else if (text === "w" || text === "W") { setTab("Wireless"); place("tab:Wireless") }
    else if (text === "r") { MonitorService.refresh(); refreshBrightness() }
    else if (text === "m" && cursorKey.indexOf("box:") === 0) moving = boxName(stopIndex("box:"))
  }
  onCursorKeyChanged: defer(revealCursor)
  onTestingChanged: {
    now = Date.now()
    if (testing) { moving = ""; defer(function() { view.place("revert") }) }
  }

  Connections {
    target: view.host
    ignoreUnknownSignals: true
    function onOpenedChanged() {
      if (view.host.opened) {
        cursor.reset()
        view.moving = ""
        scroll.contentY = 0
        view.refreshBrightness()
      }
    }
    function onEditingSettingsChanged() {
      if (view.editing) defer(function() { settingsPage.resetScroll(); settingsPage.focusBack() })
      else view.forceActiveFocus()
    }
  }
  // The body is built lazily on the first open, which can already be into
  // Settings (IPC `settings`) or a running trial: the change handlers above
  // fired before this view existed, so apply their effect here.
  Component.onCompleted: {
    ensureSelection()
    refreshBrightness()
    if (editing) defer(function() { settingsPage.resetScroll(); settingsPage.focusBack() })
    else if (testing) defer(function() { view.place("revert") })
  }
  // Focus is requested even without a window (offscreen tests); activeFocus follows once shown.
  readonly property bool settingsBackFocused: settingsPage.backTarget ? settingsPage.backTarget.focus : false
  Connections {
    target: MonitorService
    function onTransactionChanged() { view.defer(view.ensureSelection) }
  }
  function ensureSelection() {
    if (selected || !transaction.draft.length) return
    var focused = transaction.draft.find(function(m) { return m.name === MonitorService.focusedMonitor })
      || transaction.draft.find(function(m) { return m.focused }) || transaction.draft[0]
    if (focused) selectMonitor(focused.id)
  }
  onBrightnessTargetChanged: refreshBrightness()

  Timer {
    interval: 100
    repeat: true
    running: view.testing && view.host.opened === true
    onTriggered: view.now = Date.now()
  }
  // External brightness changes show up while the popup is open.
  Timer {
    interval: 5000
    repeat: true
    running: view.host.opened === true && !view.editing
    onTriggered: view.refreshBrightness()
  }

  function itemFor(key) {
    if (key.indexOf("tab:") === 0) return tabRepeater.itemAt(tabs.indexOf(key.slice(4)))
    if (key.indexOf("box:") === 0) return diagram.boxItem(stopIndex("box:"))
    if (key.indexOf("offline:") === 0) return offlineRepeater.itemAt(stopIndex("offline:"))
    if (key.indexOf("peer:") === 0) return peerRepeater.itemAt(stopIndex("peer:"))
    return ({ identify: identifyButton, power: powerButton, brightness: brightnessRow, scan: scanButton })[key] || dropdownFor(key)
  }
  function revealCursor() {
    var item = itemFor(cursorKey)
    if (!item || !item.visible) return
    var ancestor = item
    while (ancestor && ancestor !== content) ancestor = ancestor.parent
    if (!ancestor) return
    var point = item.mapToItem(content, 0, 0)
    var margin = FoamyStyle.gap
    if (point.y < scroll.contentY) scroll.contentY = Math.max(0, point.y - margin)
    else if (point.y + item.height > scroll.contentY + scroll.height)
      scroll.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.height, point.y + item.height - scroll.height + margin))
  }

  // ---- Main view ----------------------------------------------------------
  Item {
    id: main
    anchors.fill: parent
    visible: !view.editing

    // The foamy hero band, title row only: tabs, fields and sliders stay in the body.
    FoamyHeroBand {
      id: header
      width: parent.width
      iconName: "monitor"
      title: view.tr("Displays")
      meta: MonitorService.activelyCasting ? view.tr("Casting to %1", MonitorService.castTargetName)
        : view.transaction.draft.length ? FoamyI18n.tn("%1 displays on", view.activeCount) : ""
      showSettings: !view.testing
      settingsHasCursor: view.hasCursor("settings")
      onSettingsClicked: view.host.openSettings()
      onSettingsHovered: function(hovered) { if (hovered) view.hover("settings") }
    }

    Item {
      id: tabBar
      anchors.top: header.bottom
      width: parent.width
      height: FoamyStyle.controlHeight + FoamyStyle.gap * 2
      Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: FoamyPalette.divider }
      Row {
        anchors.left: parent.left
        anchors.leftMargin: FoamyStyle.padding - FoamyStyle.gap
        anchors.bottom: parent.bottom
        spacing: FoamyStyle.gapSmall
        enabled: !view.testing
        Repeater {
          id: tabRepeater
          model: view.tabs
          FoamyAction {
            id: tabButton
            required property string modelData
            iconName: ""
            label: view.tr(modelData)
            height: FoamyStyle.controlHeight
            foreground: view.activeTab === modelData ? FoamyPalette.text : FoamyPalette.secondaryText
            hasCursor: view.hasCursor("tab:" + modelData)
            onHoveredChanged: if (hovered) view.hover("tab:" + modelData)
            onClicked: view.setTab(modelData)
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.margins: FoamyStyle.gapSmall
              anchors.bottomMargin: 0
              height: 2
              radius: 1
              color: FoamyPalette.text
              visible: view.activeTab === tabButton.modelData
            }
          }
        }
      }
    }

    Flickable {
      id: scroll
      anchors.top: tabBar.bottom
      anchors.bottom: footer.top
      width: parent.width
      clip: true
      contentWidth: width
      contentHeight: content.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: !MonitorService.arrangementDragActive
      onContentHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
      QQC.ScrollBar.vertical: QQC.ScrollBar { policy: scroll.contentHeight > scroll.height ? QQC.ScrollBar.AsNeeded : QQC.ScrollBar.AlwaysOff }

      Column {
        id: content
        width: scroll.width
        padding: FoamyStyle.padding
        spacing: FoamyStyle.sectionGap
        readonly property real inner: width - FoamyStyle.padding * 2

        Label {
          width: content.inner
          visible: view.actionError !== ""
          text: view.tr(view.actionError)
          color: Commons.Color.urgent
          wrapMode: Text.WordWrap
          Accessible.role: Accessible.AlertMessage
        }
        Label {
          width: content.inner
          visible: !view.transaction.draft.length && !view.actionError
          text: view.tr("Reading displays…")
          color: FoamyPalette.mutedText
          small: true
        }

        // ---- Display ----
        Column {
          width: content.inner
          visible: view.activeTab === "Display" && view.transaction.draft.length > 0
          spacing: FoamyStyle.sectionGap
          enabled: !view.busy

          Rectangle {
            width: parent.width
            height: layoutContent.implicitHeight + FoamyStyle.sectionGap * 2
            radius: FoamyStyle.radius
            color: FoamyPalette.fieldFill
            Column {
              id: layoutContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: FoamyStyle.sectionGap
              spacing: FoamyStyle.rowPadding
              ArrangementDiagram {
                id: diagram
                width: parent.width
                visible: view.enabledMonitorInfos.length > 0
              }
              RowLayout {
                width: parent.width
                Label {
                  Layout.fillWidth: true
                  text: view.moving ? view.tr("Arrows move %1. Enter or Esc to finish.", view.friendlyDisplayName(view.transaction.draft.find(function(m) { return m.name === view.moving }) || { name: view.moving }))
                    : view.cursorKey.indexOf("box:") === 0 ? view.tr("Press M to move it with the arrow keys")
                    : view.tr("Drag to arrange")
                  color: FoamyPalette.secondaryText
                  small: true
                  elide: Text.ElideRight
                }
                FoamyAction {
                  id: identifyButton
                  iconName: "scan"
                  label: view.tr("Identify")
                  tooltipText: view.tr("Identify displays")
                  foreground: FoamyPalette.secondaryText
                  hasCursor: view.hasCursor("identify")
                  onHoveredChanged: if (hovered) view.hover("identify")
                  onClicked: MonitorService.showIdentify()
                }
              }
            }
          }

          // Disabled or disconnected drafts must remain selectable outside the diagram.
          Repeater {
            id: offlineRepeater
            model: view.offlineMonitors
            FoamyCursorSurface {
              id: offlineRow
              required property var modelData
              required property int index
              width: parent.width
              height: FoamyStyle.rowHeight
              hasCursor: view.hasCursor("offline:" + index)
              current: view.selectedMonitor === modelData.id
              onHovered: view.hover("offline:" + index)
              onClicked: view.selectMonitor(modelData.id)
              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: FoamyStyle.rowPadding
                anchors.rightMargin: FoamyStyle.rowPadding
                spacing: FoamyStyle.rowPadding
                FoamyIcon {
                  name: "monitor"
                  color: FoamyPalette.secondaryText
                  Layout.preferredWidth: FoamyStyle.iconSize
                  Layout.preferredHeight: FoamyStyle.iconSize
                }
                Label {
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                  text: view.friendlyDisplayName(offlineRow.modelData) + " · " + view.tr(!offlineRow.modelData.connected ? "Disconnected" : offlineRow.modelData.mirrorOf ? "Mirrored" : "Off")
                }
              }
            }
          }

          Field {
            id: modeField
            width: parent.width
            stop: "mode"
            label: "Display mode"
            dirty: view.marked("mirror")
            currentValue: view.selected ? view.selected.mirrorOf : ""
            options: view.mirrorOptions
            enabled: !!view.selected && view.selected.connected && !view.selected.disabled
            onChanged: function(value) { view.setMirror(value) }
          }
          RowLayout {
            width: parent.width
            Label {
              text: view.selected ? view.friendlyDisplayName(view.selected) : ""
              Layout.fillWidth: true
              elide: Text.ElideRight
            }
            Button {
              id: powerButton
              text: view.tr(view.selected && view.selected.disabled ? "Turn on" : "Turn off")
              enabled: !!view.selected && view.selected.connected && (view.selected.disabled || view.activeCount > 1)
              hasCursor: view.hasCursor("power")
              onHovered: function(hovered) { if (hovered) view.hover("power") }
              onClicked: view.toggleDisplay()
            }
          }
          GridLayout {
            width: parent.width
            columns: 2
            columnSpacing: FoamyStyle.sectionGap
            rowSpacing: FoamyStyle.sectionGap
            enabled: !!view.selected && view.selected.connected
            Field {
              id: resolutionField
              Layout.fillWidth: true
              stop: "resolution"
              label: "Resolution"
              dirty: view.marked("resolution")
              options: Model.resolutionOptions(view.selected)
              currentValue: view.selected ? view.selected.width + "x" + view.selected.height : ""
              onChanged: function(value) { view.setResolution(value) }
            }
            Field {
              id: rateField
              Layout.fillWidth: true
              stop: "rate"
              label: "Refresh rate"
              dirty: view.marked("rate")
              options: view.rateOptions
              currentValue: view.selected ? String(view.selected.refreshRate) : ""
              onChanged: function(value) { view.edit({ refreshRate: Number(value) }) }
            }
            Field {
              id: scaleField
              Layout.fillWidth: true
              stop: "scale"
              label: "Scale"
              dirty: view.marked("scale")
              options: view.scaleOptions
              currentValue: view.scaleValue
              onChanged: function(value) { view.edit({ scale: Number(value) }) }
            }
            Field {
              id: orientationField
              Layout.fillWidth: true
              stop: "orientation"
              label: "Orientation"
              dirty: view.marked("rotation")
              options: view.rotationOptions.map(function(o) { return { value: o.value, label: view.tr(o.label) } })
              currentValue: view.selected ? String(view.selected.transform) : "0"
              onChanged: function(value) { view.edit({ transform: Number(value) }) }
            }
          }
          FoamyCursorSurface {
            id: brightnessRow
            width: parent.width
            height: brightnessColumn.implicitHeight + FoamyStyle.gap * 2
            hasCursor: view.hasCursor("brightness")
            onHovered: view.hover("brightness")
            Column {
              id: brightnessColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: FoamyStyle.gap
              anchors.rightMargin: FoamyStyle.gap
              spacing: FoamyStyle.gap
              RowLayout {
                width: parent.width
                Label { text: view.tr("Brightness"); color: FoamyPalette.secondaryText; small: true; Layout.fillWidth: true }
                Label {
                  text: view.brightnessAvailable ? FoamyI18n.t("%1%", view.brightnessPercent) : view.brightnessState ? view.tr("Unavailable") : ""
                  color: FoamyPalette.secondaryText
                  small: true
                }
              }
              PanelSlider {
                width: parent.width
                bar: view.host.bar
                minimum: 1
                maximum: 100
                step: 1
                integer: true
                value: view.brightnessPercent
                enabled: view.brightnessAvailable
                opacity: enabled ? 1 : FoamyStyle.disabledOpacity
                onMoved: function(value) { MonitorService.setBrightness(view.brightnessTarget, value) }
              }
            }
          }
        }

        // ---- Advanced ----
        GridLayout {
          width: content.inner
          visible: view.activeTab === "Advanced"
          enabled: !view.busy
          columns: 2
          columnSpacing: FoamyStyle.sectionGap
          rowSpacing: FoamyStyle.sectionGap
          Field {
            id: textSizeField
            Layout.fillWidth: true
            stop: "textSize"
            label: "Text size"
            options: view.pxOptions(["9", "10", "11", "12", "14", "16", "20"])
            currentValue: String(Style.font.baseSize)
            enabled: !MonitorService.advancedBusy
            onChanged: function(value) { MonitorService.setTextSize(value) }
          }
          Field {
            id: cursorSizeField
            Layout.fillWidth: true
            stop: "cursorSize"
            label: "Cursor size"
            options: view.pxOptions(["24", "30", "36", "48", "72", "96"])
            currentValue: String(MonitorService.cursorSize)
            enabled: !MonitorService.advancedBusy
            onChanged: function(value) { MonitorService.setCursorSize(value) }
          }
          Field {
            id: gtkScaleField
            Layout.fillWidth: true
            stop: "gtkScale"
            label: "GTK scale"
            dirty: view.gtkScale.base !== view.gtkScale.value
            options: view.gtkScaleOptions
            currentValue: view.gtkScale.value === null ? view.tr("Unavailable") : String(view.gtkScale.value)
            enabled: view.gtkScale.value !== null && view.gtkScale.error === ""
            onChanged: function(value) { MonitorService.enqueue("gtk-scale", { value: Number(value) }) }
          }
          Label {
            Layout.fillWidth: true
            Layout.columnSpan: 2
            text: view.tr(view.gtkScale.error || "Text and cursor size apply immediately. GTK scale is included in Save; reopen apps after keeping it.")
            color: view.gtkScale.error ? Commons.Color.urgent : FoamyPalette.secondaryText
            small: true
            wrapMode: Text.WordWrap
          }
        }

        // ---- Wireless ----
        Column {
          width: content.inner
          visible: view.activeTab === "Wireless"
          spacing: FoamyStyle.gapLarge
          enabled: !view.busy
          RowLayout {
            width: parent.width
            Label { text: view.tr("Wireless displays"); Layout.fillWidth: true }
            Button {
              id: scanButton
              text: view.tr(MonitorService.castRunning ? "Stop" : "Scan")
              enabled: MonitorService.castRunning ? !MonitorService.castExpectedStop : !MonitorService.scanning
              hasCursor: view.hasCursor("scan")
              onHovered: function(hovered) { if (hovered) view.hover("scan") }
              onClicked: view.scanOrStop()
            }
          }
          Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            topPadding: FoamyStyle.padding
            bottomPadding: FoamyStyle.padding
            visible: text !== ""
            text: MonitorService.castRunning ? view.wirelessPhaseLabel()
              : MonitorService.wirelessError ? view.tr(MonitorService.wirelessError)
              : MonitorService.scanning ? view.tr("Scanning…")
              : MonitorService.wirelessScanState === "idle" || MonitorService.wirelessPeers.length ? "" : view.tr("No receivers found")
            color: MonitorService.wirelessError && !MonitorService.castRunning ? Commons.Color.urgent : FoamyPalette.mutedText
            small: true
          }
          Repeater {
            id: peerRepeater
            model: !MonitorService.castRunning && !MonitorService.scanRunning ? MonitorService.wirelessPeers : []
            FoamyCursorSurface {
              id: peerRow
              required property var modelData
              required property int index
              width: parent.width
              height: FoamyStyle.rowHeight
              hasCursor: view.hasCursor("peer:" + index)
              onHovered: view.hover("peer:" + index)
              onClicked: view.connectPeer(modelData)
              Accessible.role: Accessible.Button
              Accessible.name: view.peerLabel(modelData)
              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: FoamyStyle.rowPadding
                anchors.rightMargin: FoamyStyle.rowPadding
                spacing: FoamyStyle.rowPadding
                FoamyIcon {
                  name: "airplay"
                  color: FoamyPalette.secondaryText
                  Layout.preferredWidth: FoamyStyle.iconSize
                  Layout.preferredHeight: FoamyStyle.iconSize
                }
                Label { Layout.fillWidth: true; elide: Text.ElideRight; text: view.peerLabel(peerRow.modelData) }
              }
            }
          }
        }
      }
    }

    // ---- Footer: unsaved changes and the 15-second trial ----
    Item {
      id: footer
      anchors.bottom: parent.bottom
      width: parent.width
      readonly property bool shown: view.busy || view.changeCount > 0 || (MonitorService.displayChangesSaved && !view.actionError)
      height: shown ? footerContent.implicitHeight + FoamyStyle.sectionGap * 2 : 0
      visible: shown
      clip: true
      Rectangle {
        anchors.fill: parent
        bottomLeftRadius: Math.max(0, FoamyStyle.radius - FoamyStyle.borderWidth)
        bottomRightRadius: bottomLeftRadius
        color: view.busy ? FoamyPalette.fieldFill : "transparent"
      }
      Rectangle { width: parent.width; height: 1; color: FoamyPalette.divider }
      Column {
        id: footerContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: FoamyStyle.padding
        spacing: FoamyStyle.rowPadding
        Label {
          visible: view.busy
          width: parent.width
          text: view.tr(view.testing ? "Keep these settings?" : view.transaction.phase === "reverting" ? "Reverting…" : view.transaction.phase === "saving" ? "Saving…" : "Applying…")
          wrapMode: Text.WordWrap
        }
        RowLayout {
          width: parent.width
          spacing: FoamyStyle.rowPadding
          Label {
            objectName: "monitorSaveStatus"
            Layout.fillWidth: true
            text: view.testing ? FoamyI18n.tn("Reverting in %1 seconds", view.secondsLeft)
              : view.changeCount ? FoamyI18n.tn("%1 unsaved changes", view.changeCount)
              : MonitorService.displayChangesSaved && !view.actionError ? view.tr("All changes saved") : ""
            color: view.changeCount || view.testing ? view.changedColor : FoamyPalette.secondaryText
            small: true
            wrapMode: Text.WordWrap
          }
          Button {
            visible: !view.busy && view.changeCount > 0
            text: view.tr("Discard")
            hasCursor: view.hasCursor("discard")
            onHovered: function(hovered) { if (hovered) view.hover("discard") }
            onClicked: MonitorService.enqueue("discard")
          }
          Button {
            visible: view.testing
            text: view.tr("Revert")
            hasCursor: view.hasCursor("revert")
            onHovered: function(hovered) { if (hovered) view.hover("revert") }
            onClicked: view.decide("revert")
          }
          PrimaryButton {
            visible: (!view.busy && view.changeCount > 0) || view.testing
            text: view.tr(view.testing ? "Keep settings" : "Save")
            enabled: view.testing || view.changeCount > 0 && !view.busy && !MonitorService.disconnectedDraft
            hasCursor: view.hasCursor(view.testing ? "keep" : "save")
            onHovered: function(hovered) { if (hovered) view.hover(view.testing ? "keep" : "save") }
            onClicked: view.testing ? view.decide("keep") : view.save()
          }
        }
        Rectangle {
          visible: view.testing
          width: parent.width
          height: 2
          color: FoamyPalette.divider
          Rectangle {
            height: parent.height
            width: parent.width * view.secondsLeft / 15
            color: FoamyPalette.text
          }
        }
      }
    }
  }

  // ---- Settings -----------------------------------------------------------
  FoamySettingsPage {
    id: settingsPage
    visible: view.editing
    width: parent.width
    height: parent.height
    onBack: view.host.closeSettings()
    FoamySettingsSection {
      width: parent.width
      title: view.tr("Language")
      Label {
        width: parent.width
        text: view.tr("Language follows Omarchy → Setup → Language.")
        color: FoamyPalette.secondaryText
        small: true
        wrapMode: Text.WordWrap
      }
    }
    FoamySettingsSection {
      width: parent.width
      visible: view.changeCount > 0
      title: view.tr("Displays")
      Label {
        width: parent.width
        text: view.tr("Pending display changes are preserved.")
        color: FoamyPalette.secondaryText
        small: true
        wrapMode: Text.WordWrap
      }
    }
  }

  // ---- Components ---------------------------------------------------------
  component Label: Text {
    property bool small: false
    textFormat: Text.PlainText
    horizontalAlignment: Text.AlignLeft
    color: FoamyPalette.text
    font.family: FoamyStyle.fontFamily
    font.pixelSize: small ? FoamyStyle.font.bodySmall : FoamyStyle.font.body
  }
  component Button: Ui.Button {
    bordered: true
    fontFamily: FoamyStyle.fontFamily
    fontSize: FoamyStyle.font.body
    foreground: FoamyPalette.text
    radius: FoamyStyle.radius
    opacity: enabled ? 1 : FoamyStyle.disabledOpacity
  }
  component PrimaryButton: Button {
    foreground: FoamyPalette.background
    color: hot ? Qt.alpha(FoamyPalette.text, 0.85) : FoamyPalette.text
  }
  component Field: Item {
    id: field
    property string stop: ""
    property string label: ""
    property bool dirty: false
    property string currentValue: ""
    property alias options: dropdown.options
    readonly property bool popupOpen: dropdown.popupOpen
    signal changed(string value)
    function open() { dropdown.open() }
    implicitWidth: dropdown.implicitWidth
    implicitHeight: fieldLabel.implicitHeight + FoamyStyle.gapSmall + dropdown.rowHeight
    opacity: enabled ? 1 : FoamyStyle.disabledOpacity
    onPopupOpenChanged: view.openDropdowns = Math.max(0, view.openDropdowns + (popupOpen ? 1 : -1))
    Row {
      id: fieldLabel
      spacing: FoamyStyle.gapSmall
      Label {
        text: view.tr(field.label)
        color: FoamyPalette.secondaryText
        font.pixelSize: FoamyStyle.font.caption
      }
      Label {
        text: view.tr("· changed")
        visible: field.dirty
        color: view.changedColor
        font.pixelSize: FoamyStyle.font.caption
      }
    }
    FoamyDropdown {
      id: dropdown
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      showLabel: false
      value: field.currentValue
      hasCursor: view.hasCursor(field.stop)
      onHovered: function(isHovered) { if (isHovered) view.hover(field.stop) }
      onChanged: function(value) { field.changed(value) }
    }
  }
  component ArrangementDiagram: Item {
    id: diagram
    height: Style.space(150)
    // Display geometry is spatial: never mirror it.
    LayoutMirroring.enabled: false
    LayoutMirroring.childrenInherit: true

    readonly property var boxes: view.enabledMonitorInfos.map(function(info, i) {
      var f = Model.footprint(info)
      return { name: info.name, number: i + 1, label: view.friendlyDisplayName(info), x: info.x, y: info.y, w: f.w, h: f.h,
        focused: info.id === view.selectedMonitor }
    })
    function boxItem(i) { return boxRepeater.itemAt(i) }
    readonly property real minX: boxes.reduce(function(m, b) { return Math.min(m, b.x) }, boxes.length ? boxes[0].x : 0)
    readonly property real minY: boxes.reduce(function(m, b) { return Math.min(m, b.y) }, boxes.length ? boxes[0].y : 0)
    readonly property real maxX: boxes.reduce(function(m, b) { return Math.max(m, b.x + b.w) }, boxes.length ? boxes[0].x + boxes[0].w : 1)
    readonly property real maxY: boxes.reduce(function(m, b) { return Math.max(m, b.y + b.h) }, boxes.length ? boxes[0].y + boxes[0].h : 1)
    readonly property real spanX: Math.max(1, maxX - minX)
    readonly property real spanY: Math.max(1, maxY - minY)
    // A little headroom so a box at the bounding box's edge is not flush with the frame.
    readonly property real pxPerUnit: Math.min(diagram.width / diagram.spanX, diagram.height / diagram.spanY) * 0.97
    readonly property real contentWidth: spanX * pxPerUnit
    readonly property real contentHeight: spanY * pxPerUnit

    // Logical (Hyprland-coordinate) rects of every box except the one being dragged.
    function otherLogicalRects(excludeName) {
      return boxes.filter(function(b) { return b.name !== excludeName }).map(function(b) { return { x: b.x, y: b.y, w: b.w, h: b.h } })
    }
    function commitDrag(name, logicalX, logicalY) {
      var info = view.transaction.draft.find(function(m) { return m.name === name })
      if (info && (logicalX !== info.x || logicalY !== info.y)) view.moveMonitor(name, logicalX, logicalY)
    }

    Item {
      width: diagram.contentWidth
      height: diagram.contentHeight
      anchors.centerIn: parent
      Repeater {
        id: boxRepeater
        model: diagram.boxes
        ArrangementBox {
          required property var modelData
          required property int index
          canvas: diagram
          info: modelData
          boxIndex: index
        }
      }
    }
  }

  // One draggable box. Position is the model base plus an in-flight drag
  // offset, so nothing has to be rebound when the real position flows back.
  component ArrangementBox: Rectangle {
    id: box
    required property var info
    property int boxIndex: 0
    property ArrangementDiagram canvas
    readonly property bool cursorHere: view.hasCursor("box:" + boxIndex)
    readonly property bool movingHere: view.moving === info.name

    readonly property real baseX: (info.x - canvas.minX) * canvas.pxPerUnit
    readonly property real baseY: (info.y - canvas.minY) * canvas.pxPerUnit
    property real dragDeltaX: 0
    property real dragDeltaY: 0

    x: baseX + dragDeltaX
    y: baseY + dragDeltaY
    width: Math.max(2, info.w * canvas.pxPerUnit - 2)
    height: Math.max(2, info.h * canvas.pxPerUnit - 2)
    radius: FoamyStyle.radiusSmall
    color: info.focused ? Qt.tint(FoamyPalette.background, Qt.alpha(FoamyPalette.text, 0.18))
      : cursorHere ? Qt.tint(FoamyPalette.background, FoamyPalette.hoverFill) : FoamyPalette.background
    border.width: dragArea.dragging || movingHere ? 2 : 1
    border.color: dragArea.dragging || movingHere || cursorHere || info.focused ? FoamyPalette.text : FoamyPalette.divider
    z: dragArea.dragging || movingHere ? 10 : 1
    Accessible.role: Accessible.Button
    Accessible.name: info.label
    Accessible.onPressAction: selectDisplay()
    function selectDisplay() {
      var monitor = view.transaction.draft.find(function(m) { return m.name === box.info.name })
      if (monitor) view.selectMonitor(monitor.id)
    }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: box.info.number + "\n" + box.info.label
      color: FoamyPalette.text
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.body
      elide: Text.ElideRight
      width: parent.width - FoamyStyle.gap
      horizontalAlignment: Text.AlignHCenter
    }

    MouseArea {
      id: dragArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.SizeAllCursor
      onContainsMouseChanged: if (containsMouse) view.hover("box:" + box.boxIndex)

      property bool dragging: false
      property real startCanvasX: 0
      property real startCanvasY: 0
      property real startLogicalX: 0
      property real startLogicalY: 0
      // The in-flight position in Hyprland's logical coordinates. Snapping
      // happens here, never in screen space, so a flush snap is an exact
      // integer match rather than a value that drifts once divided back.
      property real curLogicalX: 0
      property real curLogicalY: 0

      // Mapped into the canvas, which never moves while dragging.
      onPressed: function(mouse) {
        var p = mapToItem(box.parent, mouse.x, mouse.y)
        startCanvasX = p.x
        startCanvasY = p.y
        startLogicalX = box.info.x
        startLogicalY = box.info.y
        curLogicalX = startLogicalX
        curLogicalY = startLogicalY
        dragging = true
        view.moving = ""
        view.dragging = true
      }
      onPositionChanged: function(mouse) {
        if (!dragging) return
        var unit = box.canvas.pxPerUnit
        var p = mapToItem(box.parent, mouse.x, mouse.y)
        var rawX = startLogicalX + (p.x - startCanvasX) / unit
        var rawY = startLogicalY + (p.y - startCanvasY) / unit
        var snap = Style.space(8) / unit
        var others = box.canvas.otherLogicalRects(box.info.name)
        var w = box.info.w, h = box.info.h
        var bestDX = null, bestDY = null
        for (var i = 0; i < others.length; i++) {
          var o = others[i]
          var candidatesX = [o.x + o.w / 2 - rawX - w / 2, o.x - rawX, (o.x + o.w) - (rawX + w), o.x - (rawX + w), (o.x + o.w) - rawX]
          for (var cx = 0; cx < candidatesX.length; cx++)
            if (Math.abs(candidatesX[cx]) <= snap && (bestDX === null || Math.abs(candidatesX[cx]) < Math.abs(bestDX))) bestDX = candidatesX[cx]
          var candidatesY = [o.y + o.h / 2 - rawY - h / 2, o.y - rawY, (o.y + o.h) - (rawY + h), o.y - (rawY + h), (o.y + o.h) - rawY]
          for (var cy = 0; cy < candidatesY.length; cy++)
            if (Math.abs(candidatesY[cy]) <= snap && (bestDY === null || Math.abs(candidatesY[cy]) < Math.abs(bestDY))) bestDY = candidatesY[cy]
        }
        if (bestDX !== null) rawX += bestDX
        if (bestDY !== null) rawY += bestDY
        // Whole logical pixels; overlap is only resolved on drop, so a display
        // can be swung across another one mid-gesture.
        curLogicalX = Math.round(rawX)
        curLogicalY = Math.round(rawY)
        box.dragDeltaX = (curLogicalX - box.info.x) * unit
        box.dragDeltaY = (curLogicalY - box.info.y) * unit
      }
      onCanceled: {
        dragging = false
        view.dragging = false
        box.dragDeltaX = 0
        box.dragDeltaY = 0
      }
      onReleased: {
        var monitorName = box.info.name
        dragging = false
        view.dragging = false
        var resolved = Model.resolveMonitorOverlap({ x: curLogicalX, y: curLogicalY, w: box.info.w, h: box.info.h },
          box.canvas.otherLogicalRects(box.info.name))
        box.canvas.commitDrag(box.info.name, resolved.x, resolved.y)
        box.dragDeltaX = 0
        box.dragDeltaY = 0
        // Selecting rebuilds the diagram's delegates, so wait until release ends.
        view.defer(function() {
          var monitor = view.transaction.draft.find(function(m) { return m.name === monitorName })
          if (monitor) view.selectMonitor(monitor.id)
        })
      }
    }
  }
}
