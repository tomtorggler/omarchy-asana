import QtQuick
import qs.Commons
import qs.Ui

// A My Tasks section heading in the list: fold chevron, name, open count.
CursorSurface {
  id: header
  implicitHeight: Style.space(34)

  property string name: ""
  property int count: 0
  property bool collapsed: false
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  signal activated()
  signal hovered()

  Row {
    anchors.left: parent.left
    anchors.leftMargin: Style.space(4)
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(6)
    spacing: Style.space(8)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(14)
      text: String.fromCodePoint(header.collapsed ? 0xF0142 : 0xF0140) // nf-md-chevron_right / _down
      color: header.dim
      font.family: header.fontFamily
      font.pixelSize: Style.font.body
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: header.name
      color: header.foreground
      font.family: header.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: String(header.count)
      color: header.dim
      font.family: header.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onPositionChanged: header.hovered()
    onClicked: header.activated()
  }
}
