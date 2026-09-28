import QtQuick
import qs.Commons
import qs.Ui

// One task in the list: completion circle, name, subtask count, project
// chip (or parent task for subtasks), due date.
CursorSurface {
  id: row
  implicitHeight: Style.space(30)

  property var task: null
  property color dim: Qt.darker(foreground, 1.5)
  property color faint: Util.alpha(foreground, 0.12)
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  readonly property bool completed: task ? task.completed : false
  readonly property var project: task && task.projects.length > 0 ? task.projects[0] : null
  readonly property string chipLabel: project
    ? project.name + (task.projects.length > 1 ? " +" + (task.projects.length - 1) : "")
    : (task && task.parentName ? "↳ " + task.parentName : "")

  signal activated()
  signal completeToggled()
  signal hovered()

  function toneColor(tone) {
    if (row.completed) return row.dim
    if (tone === "overdue") return row.urgent
    if (tone === "soon") return row.accent
    return row.foreground
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onPositionChanged: row.hovered()
    onClicked: row.activated()
  }

  Item {
    anchors.fill: parent
    anchors.leftMargin: Style.space(26)
    anchors.rightMargin: Style.space(8)

    Text {
      id: circle
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: row.completed ? String.fromCodePoint(0xF05E1)          // nf-md-check_circle_outline
        : (row.task && row.task.milestone ? "◇" : String.fromCodePoint(0xF0130)) // nf-md-checkbox_blank_circle_outline
      color: row.completed || circleArea.containsMouse ? row.accent : row.dim
      font.family: row.fontFamily
      font.pixelSize: Style.font.body

      MouseArea {
        id: circleArea
        anchors.fill: parent
        anchors.margins: -Style.space(5)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPositionChanged: row.hovered()
        onClicked: row.completeToggled()
      }
    }

    Text {
      id: due
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(92)
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: row.task ? row.task.due.label : ""
      color: row.task ? row.toneColor(row.task.due.tone) : row.foreground
      font.family: row.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Rectangle {
      id: chip
      visible: row.chipLabel !== ""
      anchors.right: due.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? Math.min(chipRow.implicitWidth + Style.space(12), Style.space(170)) : 0
      height: Style.space(20)
      radius: Math.min(Style.space(4), Style.cornerRadius + Style.space(2))
      color: row.project ? row.faint : "transparent"
      opacity: row.completed ? 0.5 : 1

      Row {
        id: chipRow
        anchors.left: parent.left
        anchors.leftMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Rectangle {
          visible: !!row.project
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(8)
          height: width
          radius: Style.space(2)
          color: row.project && row.project.color ? row.project.color : row.dim
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, Style.space(170) - Style.space(row.project ? 32 : 12))
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: row.chipLabel
          color: row.project ? row.foreground : row.dim
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Text {
      id: subtasks
      visible: row.task !== null && row.task.subtasks > 0
      anchors.right: chip.visible ? chip.left : due.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: row.task ? row.task.subtasks + " " + String.fromCodePoint(0xF0645) : "" // nf-md-file_tree
      color: row.dim
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.left: circle.right
      anchors.leftMargin: Style.space(10)
      anchors.right: subtasks.visible ? subtasks.left : (chip.visible ? chip.left : due.left)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: row.task ? row.task.name : ""
      color: row.completed ? row.dim : row.foreground
      font.strikeout: row.completed
      font.family: row.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  Rectangle {
    anchors.left: parent.left
    anchors.leftMargin: Style.space(26)
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Style.spacing.hairline
    color: row.faint
  }
}
