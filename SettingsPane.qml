import QtQuick
import QtQuick.Layouts
import "Preferences.js" as Preferences
import qs.Commons

Column {
  id: root
  required property var settings
  required property string language
  property bool saving: false
  property string error: ""
  property bool pendingDisplayChanges: false
  property alias backTarget: backButton
  signal back
  signal save(string key, var value)
  function tr(text) {
    return Preferences.text(text, language)
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
    Text {
      text: root.tr("Saving…")
      visible: root.saving
      color: root.secondary
      font.family: "sans-serif"
      font.pixelSize: Style.space(11)
    }
  }
  MonitorDropdown {
    width: parent.width - root.padding * 2
    label: root.tr("Language")
    fontFamily: "sans-serif"
    value: Preferences.value(root.settings, "language")
    enabled: !root.saving
    options: [
      {
        value: "system",
        label: root.tr("System")
      },
      {
        value: "en",
        label: "English"
      },
      {
        value: "nb",
        label: "Norsk bokmål"
      }
    ]
    onChanged: function (value) {
      root.save("language", value)
    }
  }
  Text {
    width: parent.width - root.padding * 2
    visible: root.error !== "" || root.pendingDisplayChanges
    text: root.error || (root.pendingDisplayChanges ? root.tr("Pending display changes are preserved.") : "")
    color: root.error ? Color.urgent : root.secondary
    font.family: "sans-serif"
    font.pixelSize: Style.space(12)
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    Accessible.role: root.error ? Accessible.AlertMessage : Accessible.StaticText
  }
}
