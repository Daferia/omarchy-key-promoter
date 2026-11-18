import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Promoter.js" as Promoter

// The card. Colors, font, radius and border come from the shell's theme
// singletons, so it follows `omarchy theme set` like every other surface.
// It stays up for `duration` ms (15s by default) or until you click it or
// its close button. Only the card itself takes clicks; the rest of the
// screen passes through, and it never takes keyboard focus.
Item {
  id: root

  property var shell: null
  property int duration: 15000
  // top-left | top-center | top-right | bottom-left | bottom-center | bottom-right
  property string position: "bottom-right"
  property bool showCount: true

  property bool opened: false
  property var chips: []
  property string description: ""
  property int count: 0
  property real remaining: 1

  readonly property string vertical: position.indexOf("top") === 0 ? "top" : "bottom"
  readonly property string horizontal: position.indexOf("-left") > 0 ? "left" : (position.indexOf("-right") > 0 ? "right" : "center")

  readonly property string barPosition: shell && shell.barConfig ? String(shell.barConfig.position || "top") : "top"
  readonly property bool barVisible: shell && shell.bar ? !shell.bar.barHidden : true
  readonly property int barSize: shell && shell.bar && barVisible ? Math.max(0, shell.bar.barSize) : Style.bar.sizeHorizontal
  // Clear the bar only on the edge the toast shares with it.
  function margin(edge) { return Style.space(12) + (barPosition === edge && barVisible ? barSize + Style.gapsOut : 0) }
  readonly property int edgeMargin: margin(vertical)
  readonly property int sideMargin: margin(horizontal)

  readonly property int pad: Style.space(12)
  readonly property int slide: Style.space(8)

  function show(combo, text, times) {
    chips = Promoter.chips(combo)
    description = String(text || "")
    count = times || 0
    opened = true
    countdown.restart()
  }

  function hide() {
    opened = false
    countdown.stop()
  }

  // Drives both the auto-close and the progress line along the bottom.
  NumberAnimation {
    id: countdown
    target: root
    property: "remaining"
    from: 1
    to: 0
    duration: root.duration
    onFinished: root.opened = false
  }

  PanelWindow {
    id: panel
    // Stay mounted while the fade-out finishes.
    visible: root.opened || card.opacity > 0.01
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "daferia-key-promoter"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Only the card takes clicks, and only while it is showing.
    mask: Region { item: root.opened ? card : null }

    BorderSurface {
      id: card
      x: root.horizontal === "left" ? root.sideMargin
        : root.horizontal === "right" ? panel.width - card.width - root.sideMargin
        : Math.round((panel.width - card.width) / 2)
      y: root.vertical === "bottom"
        ? panel.height - card.height - root.edgeMargin + (root.opened ? 0 : root.slide)
        : root.edgeMargin - (root.opened ? 0 : root.slide)
      width: card.borderLeft + root.pad + row.implicitWidth + root.pad + card.borderRight
      height: card.borderTop + root.pad + row.implicitHeight + root.pad + card.borderBottom
      color: Util.alpha(Color.popups.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.97

      Behavior on opacity { NumberAnimation { duration: Style.duration(root.opened ? 180 : 120); easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
      Behavior on y { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

      // Clicking anywhere on the card dismisses it.
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.hide()
      }

      Row {
        id: row
        x: card.borderLeft + root.pad
        y: card.borderTop + root.pad
        spacing: Style.space(10)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "󰌌"
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge * 0.75
          color: Color.accent
        }

        Row {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)
          Repeater {
            model: root.chips
            delegate: Row {
              required property string modelData
              required property int index
              spacing: Style.space(4)
              Text {
                visible: index > 0
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "+"
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                color: Util.alpha(Color.popups.text, 0.5)
              }
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: label.implicitWidth + Style.space(12)
                height: label.implicitHeight + Style.space(6)
                radius: Math.min(Style.cornerRadius, Style.space(4))
                color: Util.alpha(Color.accent, 0.12)
                border.width: 1
                border.color: Util.alpha(Color.accent, 0.6)
                Text {
                  id: label
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: modelData
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  color: Color.popups.text
                }
              }
            }
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.description
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          color: Color.popups.text
          elide: Text.ElideRight
          maximumLineCount: 1
          width: Math.min(implicitWidth, Style.space(260))
        }

        Text {
          visible: root.showCount && root.count > 1
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "×" + root.count
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          color: Util.alpha(Color.popups.text, 0.5)
        }

        // Close button.
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: closeGlyph.implicitHeight + Style.space(6)
          height: width
          radius: width / 2
          color: closeArea.containsMouse ? Util.alpha(Color.popups.text, 0.12) : "transparent"
          Text {
            id: closeGlyph
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "󰅖"
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            color: Util.alpha(Color.popups.text, closeArea.containsMouse ? 0.9 : 0.55)
          }
          MouseArea {
            id: closeArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.hide()
          }
        }
      }

      // Time left before it closes on its own.
      Rectangle {
        x: card.borderLeft + root.pad
        y: card.height - card.borderBottom - Style.space(5)
        height: Math.max(1, Style.space(2))
        radius: height / 2
        width: (card.width - card.borderLeft - card.borderRight - root.pad * 2) * root.remaining
        color: Util.alpha(Color.accent, 0.5)
      }
    }
  }
}
