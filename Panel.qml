import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Asana "My tasks" in the bar: an icon with the number of tasks that need
// attention, and a popup with the list view grouped by My Tasks sections.
// Every monitor's widget binds to the plugin's one AsanaService; this file is
// the button, the popup layout and the keyboard cursor.
Panel {
  id: root
  moduleName: "io.github.tomtorggler.asana"
  ipcTarget: moduleName
  manageIpc: false

  readonly property var asana: root.bar && root.bar.shell ? root.bar.shell.serviceFor(root.moduleName) : null
  readonly property var snapshot: asana ? asana.snapshot : null
  readonly property var counts: asana ? asana.counts : Model.summary(null, "")
  readonly property bool canWrite: asana ? asana.canWrite : false
  readonly property bool needsLogin: asana ? asana.needsLogin : false
  readonly property var rows: asana ? Model.flattenRows(asana.sections, asana.collapsed) : []

  readonly property string badge: String(setting("badge", "due") || "due")
  readonly property int badgeCount: badge === "open" ? counts.open : (badge === "none" ? 0 : counts.overdue + counts.dueToday)

  property int cursorIndex: -1
  property bool adding: false
  readonly property var currentRow: cursorIndex >= 0 && cursorIndex < rows.length ? rows[cursorIndex] : null

  readonly property color foreground: root.bar ? root.bar.foreground : Color.popups.text
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color faint: Util.alpha(foreground, 0.12)
  readonly property color urgent: root.bar ? root.bar.urgent : Color.urgent
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property bool vertical: root.bar ? root.bar.vertical : false

  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  // The service reads its settings from this widget's shell.json entry.
  function configureService() {
    if (!root.asana) return
    root.asana.workspace = String(root.setting("workspace", "") || "")
    root.asana.refreshIntervalSec = Math.max(60, parseInt(root.setting("refreshIntervalSec", 300), 10) || 300)
  }

  onAsanaChanged: configureService()
  onSettingsChanged: configureService()

  // ---- Cursor and actions

  function indexOfKey(key, fallbackKey) {
    var fallback = -1
    for (var i = 0; i < root.rows.length; i++) {
      if (root.rows[i].key === key) return i
      if (root.rows[i].key === fallbackKey) fallback = i
    }
    return fallback
  }

  function toggleSection(sectionGid) {
    var key = root.currentRow ? root.currentRow.key : ""
    root.asana.toggleSection(sectionGid)
    // A folded task row disappears; keep the cursor on its section instead.
    if (key !== "") root.cursorIndex = root.indexOfKey(key, "s:" + sectionGid)
  }

  function moveCursor(dx, dy) {
    if (root.rows.length === 0) return
    if (dy !== 0) {
      var next = root.cursorIndex < 0 ? (dy > 0 ? 0 : root.rows.length - 1) : root.cursorIndex + dy
      root.cursorIndex = Math.max(0, Math.min(root.rows.length - 1, next))
      return
    }
    // Left folds the current section, right unfolds it.
    var row = root.currentRow
    if (!row) return
    var isCollapsed = root.asana.collapsed[row.sectionGid] === true
    if ((dx < 0 && !isCollapsed) || (dx > 0 && isCollapsed)) root.toggleSection(row.sectionGid)
    else if (dx < 0 && row.kind === "task") root.cursorIndex = root.indexOfKey("s:" + row.sectionGid, "")
  }

  function activateRow(index) {
    var row = root.rows[index]
    if (!row) return
    if (row.kind === "section") root.toggleSection(row.sectionGid)
    else root.openUrl(row.task.url)
  }

  function activateCursor() {
    if (root.needsLogin && !root.snapshot) root.signIn()
    else if (root.cursorIndex >= 0) root.activateRow(root.cursorIndex)
  }

  function completeCursor() {
    if (root.currentRow && root.currentRow.kind === "task") root.asana.toggleComplete(root.currentRow.task)
  }

  function startAdding() {
    if (!root.canWrite) return
    root.adding = true
    Qt.callLater(function() {
      addField.text = ""
      addField.forceActiveFocus()
    })
  }

  function stopAdding() {
    root.adding = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function submitAdd() {
    if (root.asana.addTask(addField.text)) root.stopAdding()
  }

  function openUrl(url) {
    if (!url) return
    Quickshell.execDetached(["omarchy-launch-browser", url])
    root.close()
  }

  function openMyTasks() {
    root.openUrl(Model.myTasksUrl(root.snapshot))
  }

  function signIn() {
    // The launcher runs its arguments through bash -c, so quote the path.
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", Util.shellQuote(root.asana.loginPath)])
    root.close()
  }

  function refresh() {
    if (root.asana) root.asana.refresh()
  }

  function statusLine() {
    if (root.snapshot === null) return root.asana && root.asana.loading ? "Loading…" : ""
    var parts = [root.counts.open + (root.snapshot.truncated ? "+" : "") + " open"]
    if (root.counts.dueToday > 0) parts.push(root.counts.dueToday + " due today")
    return parts.join(" · ")
  }

  function tooltip() {
    if (root.needsLogin) return "Asana · sign in required"
    if (root.snapshot === null) return "Asana"
    return "Asana · " + root.statusLine() + (root.counts.overdue > 0 ? " · " + root.counts.overdue + " overdue" : "")
  }

  function close() {
    root.adding = false
    root.controller.hide()
  }

  onOpenedChanged: {
    if (!root.asana) return
    if (opened) {
      root.cursorIndex = -1
      root.asana.nowMs = Date.now()
      root.asana.refreshIfStale()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      root.asana.flushCompletions()
    }
  }

  onCursorIndexChanged: if (cursorIndex >= 0) taskList.positionViewAtIndex(cursorIndex, ListView.Contain)

  onRowsChanged: if (cursorIndex >= rows.length) cursorIndex = rows.length - 1

  IpcHandler {
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function add(): void { root.open(); root.startAdding() }
    function refresh(): string { root.refresh(); return root.asana ? "ok" : "unavailable" }
    function status(): string {
      return JSON.stringify({ counts: root.counts, truncated: root.snapshot ? root.snapshot.truncated === true : false, error: root.asana ? root.asana.error : null, fetchedAt: root.snapshot ? root.snapshot.fetchedAt : null })
    }
  }

  // ---- Bar button

  WidgetButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(0xF0134) // nf-md-checkbox_marked_circle_outline
      + (root.badgeCount > 0 && !root.vertical ? " " + root.badgeCount + (root.badge === "open" && root.snapshot && root.snapshot.truncated ? "+" : "") : "")
    active: root.counts.overdue > 0
    dimmed: root.snapshot === null
    tooltipText: root.tooltip()
    Accessible.role: Accessible.Button
    Accessible.name: root.tooltip()
    Accessible.onPressAction: root.toggle()
    onPressed: function(button) {
      if (button === Qt.RightButton) root.openMyTasks()
      else if (button === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // ---- Popup

  KeyboardPanel {
    id: popup
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(640))
    contentHeight: popup.fittedContentHeight(content.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.adding
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (key === "r") root.refresh()
        else if (key === "o") root.openMyTasks()
        else if (key === "c") root.completeCursor()
        else if (key === "a") root.startAdding()
      }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(8)

        // ---- Header: title, counts, freshness, actions.
        Item {
          width: parent.width
          height: Style.space(40)

          Text {
            id: title
            anchors.left: parent.left
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: "My tasks"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Row {
            anchors.left: title.right
            anchors.leftMargin: Style.space(12)
            anchors.baseline: title.baseline
            baselineOffset: statusText.baselineOffset

            Text {
              id: statusText
              textFormat: Text.PlainText
              text: root.statusLine()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              visible: root.counts.overdue > 0
              textFormat: Text.PlainText
              text: " · " + root.counts.overdue + " overdue"
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              rightPadding: Style.space(6)
              textFormat: Text.PlainText
              text: root.snapshot && root.asana ? Model.relativeTime(root.snapshot.fetchedAt, root.asana.nowMs) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            PanelActionButton {
              visible: root.canWrite
              anchors.verticalCenter: parent.verticalCenter
              iconText: String.fromCodePoint(0xF0415) // nf-md-plus
              tooltipText: "Add a task (a)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.adding ? root.stopAdding() : root.startAdding()
            }
            Button {
              anchors.verticalCenter: parent.verticalCenter
              iconText: String.fromCodePoint(0xF0450) // nf-md-refresh
              iconSpinning: root.asana ? root.asana.loading : false
              tooltipText: "Refresh (r)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.refresh()
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.spacing.hairline
            color: root.faint
          }
        }

        // ---- Quick add. New tasks are assigned to you, so Asana files them
        //      under Recently assigned.
        TextField {
          id: addField
          visible: root.adding
          width: parent.width
          placeholderText: "Add a task to Recently assigned — Enter to save, Esc to cancel"
          foreground: root.foreground
          font.family: root.fontFamily

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.stopAdding()
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.submitAdd()
              event.accepted = true
            }
          }
        }

        // ---- Errors, write feedback, sign-in and empty states.
        Text {
          visible: root.asana !== null && root.asana.error !== null
          x: Style.space(6)
          width: parent.width - Style.space(12)
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: visible ? root.asana.error.message : ""
          color: root.snapshot ? root.dim : root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          visible: root.asana !== null && root.asana.notice !== null
          x: Style.space(6)
          width: parent.width - Style.space(12)
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: visible ? root.asana.notice.text : ""
          color: visible && root.asana.notice.tone === "error" ? root.urgent : Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          visible: root.needsLogin
          x: Style.space(6)
          text: "Sign in with a personal access token"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.signIn()
        }

        Text {
          visible: root.rows.length === 0 && !(root.asana && root.asana.error)
          x: Style.space(6)
          textFormat: Text.PlainText
          text: root.asana && root.asana.loading ? "Loading your tasks…" : "Nothing assigned to you. Enjoy it."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        // ---- The list view. It owns the scroll position, so the keyboard
        //      cursor stays in view as it moves.
        ListView {
          id: taskList
          visible: root.rows.length > 0
          width: parent.width
          height: Math.min(contentHeight, Style.space(560))
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          model: root.rows
          cacheBuffer: 400
          Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

          delegate: Loader {
            id: rowLoader
            required property var modelData
            required property int index
            readonly property bool hasCursor: index === root.cursorIndex

            width: ListView.view.width
            sourceComponent: modelData.kind === "section" ? sectionComponent : taskComponent

            Component {
              id: sectionComponent
              SectionHeader {
                name: rowLoader.modelData.name
                count: rowLoader.modelData.count
                collapsed: rowLoader.modelData.collapsed
                hasCursor: rowLoader.hasCursor
                foreground: root.foreground
                dim: root.dim
                fontFamily: root.fontFamily
                onHovered: root.cursorIndex = rowLoader.index
                onActivated: root.activateRow(rowLoader.index)
              }
            }

            Component {
              id: taskComponent
              TaskRow {
                task: rowLoader.modelData.task
                hasCursor: rowLoader.hasCursor
                foreground: root.foreground
                dim: root.dim
                faint: root.faint
                urgent: root.urgent
                fontFamily: root.fontFamily
                onHovered: root.cursorIndex = rowLoader.index
                onActivated: root.activateRow(rowLoader.index)
                onCompleteToggled: root.asana.toggleComplete(task)
              }
            }
          }
        }

        // ---- Key hints.
        Text {
          x: Style.space(6)
          textFormat: Text.PlainText
          text: "↵ open · c complete · a add · h/l fold · r refresh · o open in Asana"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
