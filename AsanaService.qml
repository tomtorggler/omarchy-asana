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
// fetch leaves the file alone and reports through its stdout.
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
  // Tasks completed since the last fetch. They stay listed, checked, until a
  // fetch drops them, so a mistaken completion can be undone.
  property var completedGids: ({})
  property bool completionsPending: false
  // Short-lived feedback for writes: { text, tone: "info" | "error" }.
  property var notice: null
  property string todayYmd: Model.localYmd(new Date())
  property real nowMs: Date.now()

  readonly property var sections: Model.buildSections(snapshot, todayYmd, completedGids)
  readonly property var counts: Model.summary(snapshot, todayYmd, completedGids)
  readonly property bool needsLogin: error !== null && (error.kind === "no-token" || error.kind === "auth")
  readonly property bool canWrite: snapshot !== null && !needsLogin

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
    var command = [service.binDir + "/asana-fetch", "--quiet"]
    if (service.workspace !== "") command.push("--workspace", service.workspace)
    fetchProc.command = command
    service.loading = true
    fetchProc.running = true
  }

  function refreshIfStale() {
    var fetched = service.snapshot ? Date.parse(service.snapshot.fetchedAt) : NaN
    if (isNaN(fetched) || Date.now() - fetched > service.openRefreshSec * 1000) service.refresh()
  }

  function applySnapshot(next) {
    service.snapshot = next
    service.completedGids = Model.pruneCompleted(service.completedGids, next)
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

  function setCompleted(gid, completed) {
    var next = {}
    for (var key in service.completedGids) if (service.completedGids[key]) next[key] = true
    if (completed) next[gid] = true
    else delete next[gid]
    service.completedGids = next
  }

  // Check a task off, or reopen one checked off since the last fetch. The
  // mark shows at once and is rolled back if Asana refuses.
  function toggleComplete(task) {
    if (!task || !service.canWrite) return
    var completing = !service.completedGids[task.gid]
    service.setCompleted(task.gid, completing)
    service.completionsPending = true
    service.enqueueWrite({ kind: completing ? "complete" : "reopen", gid: task.gid, name: task.name })
  }

  function addTask(name) {
    var trimmed = String(name || "").trim()
    if (trimmed === "" || !service.canWrite) return false
    service.enqueueWrite({ kind: "add", name: trimmed })
    return true
  }

  // Let the list catch up with completions once the popup is out of the way.
  function flushCompletions() {
    if (!service.completionsPending) return
    service.completionsPending = false
    service.refresh()
  }

  function enqueueWrite(op) {
    service.writeQueue = service.writeQueue.concat([op])
    service.runNextWrite()
  }

  function runNextWrite() {
    if (service.runningWrite || service.writeQueue.length === 0) return
    var op = service.writeQueue[0]
    service.writeQueue = service.writeQueue.slice(1)
    service.runningWrite = op
    var command = [service.binDir + "/asana-task"]
    if (op.kind === "add") command.push("add", String(service.snapshot.workspace.gid), op.name)
    else command.push(op.kind, op.gid)
    taskProc.command = command
    taskProc.running = true
  }

  function finishWrite(text) {
    var op = service.runningWrite
    service.runningWrite = null
    var result = Model.parseTaskResult(text)
    if (result.error) {
      if (op.kind !== "add") service.setCompleted(op.gid, op.kind !== "complete")
      service.showNotice("Could not " + (op.kind === "add" ? "add" : op.kind) + " “" + op.name + "”: " + result.error.message, "error")
    } else if (op.kind === "add") {
      service.showNotice("Added “" + result.task.name + "” to Recently assigned", "info")
      service.refresh()
    }
    service.runNextWrite()
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
