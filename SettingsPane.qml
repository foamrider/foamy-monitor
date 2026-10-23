import QtQuick
import QtQuick.Layouts
import qs.Commons

Column {
  id: root
  required property string language
  property bool pendingDisplayChanges: false
  property alias backTarget: backButton
  signal back
  function tr(text) {
    return FoamyI18n.t(text)
  }
  function focusBack() {
    backButton.forceActiveFocus()
  }
  readonly property color secondary: Qt.tint(Color.popups.background, Qt.alpha(Color.popups.text, 0.7))
  spacing: Style.space(18)
  padding: Style.space(20)
  RowLayout {
    width: parent.width - root.padding * 2
    MonitorAction {
      id: backButton
      iconName: "arrow-left"
      tooltipText: root.tr("Back")
      foreground: root.secondary
      onClicked: root.back()
    }
    Text {
      text: root.tr("Plugin settings")
      color: root.secondary
      font.family: "sans-serif"
      font.pixelSize: Style.space(13)
      Layout.fillWidth: true
    }

  }

  Text {
    text: root.tr("Language follows Omarchy → Setup → Language.")
    width: parent.width - root.padding * 2
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: root.secondary
  }
  Text {
    width: parent.width - root.padding * 2
    visible: root.pendingDisplayChanges
    text: root.tr("Pending display changes are preserved.")
    color: root.secondary
    font.family: "sans-serif"
    font.pixelSize: Style.space(12)
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    Accessible.role: Accessible.StaticText
  }
}
