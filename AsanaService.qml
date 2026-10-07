import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The plugin's one service: the bar widget on every monitor binds to this
// instance. It runs bin/asana-fetch and bin/asana-task, owns the snapshot,
// fold state and in-session completions, and serialises writes. The scripts
// own the token and every API call; this only reads their JSON.
//
// Snapshots arrive through one inlet: the cache file asana-fetch writes, from
// this service or from a hand-run asana-login / asana-fetch. A snapshot in the
// file means a fetch succeeded, so loading one clears the error. A failed
// fetch leaves the file alone and reports through its stdout. When the file
// goes away (asana-login --logout), everything it held is cleared.
Item {
  id: service
  visible: false

  // Pushed in by the bar widget from its shell.json entry.
  property string workspace: ""
  property int refreshIntervalSec: 300
  // Sections folded on first run, before the user has folded anything.
  readonly property var initiallyCollapsed: ["Recently assigned"]
  // Opening the popup refreshes, unless the snapshot is at least this fresh.
  readonly property int openRefreshSec: 60

  property var snapshot: null
  property var error: null
  property bool loading: false
  property var collapsed: ({})
  property bool collapsedKnown: false
  // Completion marks, gid -> true: shownGids is what the list displays,
  // confirmedGids what Asana has accepted. Checked tasks stay listed until
  // a fetch drops them, so a mistaken completion can be undone.
  property var shownGids: ({})
  property var confirmedGids: ({})
  property bool completionsPending: false
  // Bumped when the cache is cleared; a write started before that is
  // ignored when it ends, so it cannot bring old marks back.
  property int generation: 0
  // Short-lived feedback for writes: { text, tone: "info" | "error" }.
  property var notice: null
  property string todayYmd: Model.localYmd(new Date())
  property real nowMs: Date.now()

  readonly property var sections: Model.buildSections(snapshot, todayYmd, shownGids)
  readonly property var counts: Model.summary(snapshot, todayYmd, shownGids)
  readonly property bool needsLogin: error !== null && (error.kind === "no-token" || error.kind === "auth")
  readonly property bool canWrite: snapshot !== null && !needsLogin && Model.workspaceMatches(snapshot, workspace)

  readonly property string binDir: decodeURIComponent(Qt.resolvedUrl("bin").toString().replace(/^file:\/\//, ""))
  readonly property string loginPath: binDir + "/asana-login"
  readonly property string home: Quickshell.env("HOME")
  readonly property string cachePath: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/omarchy-asana/tasks.json"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy-asana"

  property bool refreshQueued: false
  property var writeQueue: []
  property var runningWrite: null

  onWorkspaceChanged: refresh()

  // ---- Reading

  // Start a fetch, or run one more as soon as the current fetch finishes.
  function refresh() {
    if (fetchProc.running) {
      service.refreshQueued = true
      return
    }
    // Names go through the environment, which only this user can read; the
    // command line is visible to every local user.
    fetchProc.command = [service.binDir + "/asana-fetch", "--quiet"]
    fetchProc.environment = { ASANA_WORKSPACE: service.workspace }
    service.loading = true
    fetchProc.running = true
  }

  function refreshIfStale() {
    var fetched = service.snapshot ? Date.parse(service.snapshot.fetchedAt) : NaN
    if (isNaN(fetched) || Date.now() - fetched > service.openRefreshSec * 1000) service.refresh()
  }

  // The cache file went away, as asana-login --logout does: forget
  // everything it held instead of leaving the tasks on screen.
  function clearSnapshot() {
    var hadSnapshot = service.snapshot !== null
    service.generation++
    service.snapshot = null
    service.shownGids = {}
    service.confirmedGids = {}
    service.completionsPending = false
    service.writeQueue = []
    // Find out why (signed out, usually) rather than show an empty list.
    if (hadSnapshot) service.refresh()
  }

  function applySnapshot(next) {
    service.snapshot = next
    // A task with a write in flight keeps its marks even if this snapshot
    // already dropped it; otherwise the write's result would read the
    // missing mark as an undo and send the opposite.
    var pending = service.pendingGids()
    service.shownGids = Model.pruneCompleted(service.shownGids, next, pending)
    service.confirmedGids = Model.pruneCompleted(service.confirmedGids, next, pending)
    if (!service.collapsedKnown) {
      service.collapsed = Model.defaultCollapsed(Model.buildSections(next, service.todayYmd), service.initiallyCollapsed)
      service.collapsedKnown = true
    }
  }

  // ---- Folding

  function toggleSection(sectionGid) {
    var next = {}
    for (var gid in service.collapsed) if (service.collapsed[gid]) next[gid] = true
    if (next[sectionGid]) delete next[sectionGid]
    else next[sectionGid] = true
    service.collapsed = next
    service.collapsedKnown = true
    stateFile.setText(JSON.stringify({ collapsed: next }) + "\n")
  }

  // ---- Writing

  // Tasks with a completion write queued or running. A write left over
  // from before the cache was cleared does not count: its result is ignored.
  function pendingGids() {
    var gids = {}
    var ops = service.writeQueue.concat(service.runningWrite ? [service.runningWrite] : [])
    for (var i = 0; i < ops.length; i++)
      if (ops[i].gid && ops[i].generation === service.generation) gids[ops[i].gid] = true
    return gids
  }

  function writePending(gid) {
    return service.pendingGids()[gid] === true
  }

  // Check a task off, or reopen one checked off since the last fetch. The
  // mark shows at once. Each task has at most one write in flight; toggling
  // again meanwhile only changes the mark, and the write that follows sends
  // whatever the mark says by then. A failed write puts the mark back to
  // what Asana has.
  function toggleComplete(task) {
    if (!task || !service.canWrite) return
    var next = {}
    for (var key in service.shownGids) if (service.shownGids[key]) next[key] = true
    if (next[task.gid]) delete next[task.gid]
    else next[task.gid] = true
    service.shownGids = next
    service.completionsPending = true
    if (!service.writePending(task.gid)) service.enqueueWrite({ kind: "completion", gid: task.gid, name: task.name })
  }

  function addTask(name) {
    var trimmed = String(name || "").trim()
    if (trimmed === "" || !service.canWrite) return false
    service.enqueueWrite({ kind: "add", name: trimmed, workspaceGid: String(service.snapshot.workspace.gid) })
    return true
  }

  // Let the list catch up with completions once the popup is out of the way.
  function flushCompletions() {
    if (!service.completionsPending) return
    service.completionsPending = false
    service.refresh()
  }

  function enqueueWrite(op) {
    op.generation = service.generation
    service.writeQueue = service.writeQueue.concat([op])
    service.runNextWrite()
  }

  function runNextWrite() {
    while (!service.runningWrite && service.writeQueue.length > 0) {
      var op = service.writeQueue[0]
      service.writeQueue = service.writeQueue.slice(1)
      if (op.kind === "add") {
        taskProc.command = [service.binDir + "/asana-task", "add", op.workspaceGid]
        taskProc.environment = { ASANA_TASK_NAME: op.name }
      } else {
        var write = Model.completionWrite(op.gid, service.shownGids, service.confirmedGids)
        if (!write) continue // toggled back before it ran: nothing to send
        op.completed = write.completed
        taskProc.command = [service.binDir + "/asana-task", write.completed ? "complete" : "reopen", op.gid]
        taskProc.environment = ({})
      }
      service.runningWrite = op
      taskProc.running = true
    }
  }

  function finishWrite(text) {
    var op = service.runningWrite
    service.runningWrite = null
    if (op.generation === service.generation) service.applyWriteResult(op, Model.parseTaskResult(text))
    service.runNextWrite()
  }

  function applyWriteResult(op, result) {
    if (op.kind === "add") {
      if (result.error) {
        service.showNotice("Could not add “" + op.name + "”: " + result.error.message, "error")
      } else {
        service.showNotice("Added “" + result.task.name + "” to Recently assigned", "info")
        service.refresh()
      }
      return
    }
    var marks = Model.afterCompletionWrite(op.gid, op.completed, !result.error, service.shownGids, service.confirmedGids)
    service.shownGids = marks.shown
    service.confirmedGids = marks.confirmed
    if (result.error)
      service.showNotice("Could not " + (op.completed ? "complete" : "reopen") + " “" + op.name + "”: " + result.error.message, "error")
    else if (Model.completionWrite(op.gid, marks.shown, marks.confirmed))
      service.enqueueWrite({ kind: "completion", gid: op.gid, name: op.name })
  }

  function showNotice(text, tone) {
    service.notice = { text: text, tone: tone }
    noticeTimer.restart()
  }

  Component.onCompleted: mkdirProc.running = true

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", service.stateDir]
  }

  // With --quiet, stdout carries only an error report.
  Process {
    id: fetchProc
    stdout: StdioCollector { id: fetchOut; waitForEnd: true }
    onExited: function(exitCode) {
      service.loading = false
      // The watch only works once the file exists, so a first snapshot needs
      // an explicit read.
      if (exitCode === 0) cacheFile.reload()
      else service.error = Model.parseSnapshot(fetchOut.text).error
        || { kind: "api", message: "asana-fetch failed (exit " + exitCode + ")." }
      if (service.refreshQueued) {
        service.refreshQueued = false
        Qt.callLater(service.refresh)
      }
    }
  }

  // Every write ends here, output or not, so the queue can never stall.
  Process {
    id: taskProc
    stdout: StdioCollector { id: taskOut; waitForEnd: true }
    onExited: function(exitCode) { service.finishWrite(taskOut.text) }
  }

  FileView {
    id: cacheFile
    path: service.cachePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoadFailed: function(error) { if (error === FileViewError.FileNotFound) service.clearSnapshot() }
    onLoaded: {
      var result = Model.parseSnapshot(text())
      if (!result.snapshot) return
      service.error = null
      service.applySnapshot(result.snapshot)
    }
  }

  FileView {
    id: stateFile
    path: service.stateDir + "/state.json"
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (parsed && parsed.collapsed) {
          service.collapsed = parsed.collapsed
          service.collapsedKnown = true
        }
      } catch (e) { }
    }
  }

  Timer {
    interval: service.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: service.refresh()
  }

  // Keeps "Today"/"Tomorrow" honest across midnight and "updated 3m ago" live.
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: {
      service.todayYmd = Model.localYmd(new Date())
      service.nowMs = Date.now()
    }
  }

  Timer {
    id: noticeTimer
    interval: 6000
    onTriggered: service.notice = null
  }
}
