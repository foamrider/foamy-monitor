pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "kit"
import "Model.js" as Model

// "Identify displays": a name card on every screen for a moment. Loaded by
// the leader panel only (one card per screen, not one per bar instance), and
// only while shown.
Variants {
  model: Quickshell.screens
  delegate: PanelWindow {
    id: identifyWindow
    required property var modelData
    screen: modelData
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: Style.space(300)
    implicitHeight: Style.space(120)
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "foamy-monitor-identify"
    mask: Region {}
    Rectangle {
      anchors.fill: parent
      color: FoamyPalette.background
      border.color: Commons.Color.accent
      border.width: Style.normalBorderWidth
      radius: FoamyStyle.radius
      Text {
        anchors.centerIn: parent
        width: parent.width - FoamyStyle.padding * 2
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        textFormat: Text.PlainText
        color: FoamyPalette.text
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.display
        text: {
          var live = MonitorService.liveMonitors.find(function(m) { return m.name === identifyWindow.modelData.name })
          return FoamyI18n.t(Model.friendlyMonitorLabel(live || { name: identifyWindow.modelData.name }))
        }
      }
    }
  }
}
