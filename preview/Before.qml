import QtQuick
import qs.Ui
import ".." as Dev

// Before shots only: the dev (1.0.0) Panel with its MonitorPopup fork, fed
// by fake hyprctl/brightness on PATH (tests/fakebin.py). States use the
// same names as Preview.qml. Not loaded by the shell.
Item {
  id: preview
  required property QtObject bar
  required property Item anchorItem
  property var previewStates: ["display", "advanced", "wireless", "settings"]
  property string previewState: "display"
  property int settleMs: 3000
  readonly property Item popup: {
    var kids = FakeDisplay.overlay ? FakeDisplay.overlay.children : []
    for (var i = 0; i < kids.length; i++) if (kids[i].objectName === "monitorPopup") return kids[i]
    return panel
  }
  onPreviewStateChanged: apply()
  function apply() {
    panel.editingSettings = previewState === "settings"
    panel.activeTab = previewState === "advanced" ? "Advanced" : previewState === "wireless" ? "Wireless" : "Display"
  }
  Dev.Panel {
    id: panel
    parent: preview.anchorItem
    anchors.fill: parent
    bar: preview.bar
    Component.onCompleted: { panel.open(); preview.apply() }
  }
}
