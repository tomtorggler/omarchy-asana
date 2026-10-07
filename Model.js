/* Pure, QML-compatible task grouping and formatting. Shared with node tests. */

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

// Asana's project color names, approximated from the web app's palette.
// The dark-/light- names are the legacy palette older projects still carry.
var PROJECT_COLORS = {
  "red": "#f06a6a",
  "orange": "#f59c5a",
  "yellow-orange": "#f1bd6c",
  "yellow": "#f8df72",
  "yellow-green": "#aecf55",
  "green": "#5da283",
  "blue-green": "#4ecbc4",
  "aqua": "#9ee7e3",
  "blue": "#7a9ff5",
  "indigo": "#8d84e8",
  "purple": "#b36bd4",
  "magenta": "#f9aaef",
  "hot-pink": "#f26fb2",
  "pink": "#fc979a",
  "cool-gray": "#8a8c8d",
  "dark-pink": "#ea4e9d",
  "dark-green": "#62d26f",
  "dark-blue": "#4186e0",
  "dark-red": "#e8384f",
  "dark-teal": "#20aaea",
  "dark-brown": "#c79a67",
  "dark-orange": "#fd612c",
  "dark-purple": "#7a6ff0",
  "dark-warm-gray": "#8da3a6",
  "light-pink": "#e362e3",
  "light-green": "#a4cf30",
  "light-blue": "#4186e0",
  "light-red": "#ff7f7f",
  "light-teal": "#37c5ab",
  "light-brown": "#eec300",
  "light-orange": "#fd9a00",
  "light-purple": "#aa62e3",
  "light-warm-gray": "#8da3a6"
}

var FALLBACK_SECTION = { gid: "", name: "Other" }

function parseSnapshot(text) {
  var raw = String(text || "").trim()
  if (raw === "") return { snapshot: null, error: null }
  try {
    var parsed = JSON.parse(raw)
    if (parsed && parsed.error) return { snapshot: null, error: parsed.error }
    if (!parsed || !Array.isArray(parsed.tasks)) return { snapshot: null, error: { kind: "api", message: "Unexpected response from asana-fetch." } }
    return { snapshot: parsed, error: null }
  } catch (e) {
    return { snapshot: null, error: { kind: "api", message: "Could not parse asana-fetch output." } }
  }
}

// Output of bin/asana-task: {"task":{...}} or {"error":{...}}.
function parseTaskResult(text) {
  try {
    var parsed = JSON.parse(String(text || "").trim())
    if (parsed && parsed.task && parsed.task.gid) return { task: parsed.task, error: null }
    if (parsed && parsed.error) return { task: null, error: parsed.error }
  } catch (e) { }
  return { task: null, error: { kind: "api", message: "The Asana change could not be confirmed." } }
}

// Days since the epoch for a YYYY-MM-DD string, or NaN.
function dayNumber(ymd) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(ymd || ""))
  if (!m) return NaN
  return Math.round(Date.UTC(+m[1], +m[2] - 1, +m[3]) / 86400000)
}

function localYmd(date) {
  function pad(n) { return n < 10 ? "0" + n : String(n) }
  return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate())
}

// Due date label and tone the way Asana's list view words them: relative
// names near today, weekday names within the week, short dates otherwise.
function dueInfo(dueOn, todayYmd) {
  var due = dayNumber(dueOn)
  var today = dayNumber(todayYmd)
  if (isNaN(due) || isNaN(today)) return { label: "", tone: "" }

  var diff = due - today
  var tone = diff < 0 ? "overdue" : (diff <= 1 ? "soon" : "")
  var label
  if (diff === 0) label = "Today"
  else if (diff === 1) label = "Tomorrow"
  else if (diff === -1) label = "Yesterday"
  else if (diff > 1 && diff < 7) label = WEEKDAYS[new Date(due * 86400000).getUTCDay()]
  else {
    var parts = String(dueOn).split("-")
    label = MONTHS[+parts[1] - 1] + " " + (+parts[2])
    if (parts[0] !== String(todayYmd).slice(0, 4)) label += ", " + parts[0]
  }
  return { label: label, tone: tone }
}

function projectColor(name) {
  return PROJECT_COLORS[String(name || "")] || ""
}

function taskView(task, todayYmd, completedGids) {
  var projects = []
  var source = task.projects || []
  for (var i = 0; i < source.length; i++) {
    if (!source[i] || !source[i].name) continue
    projects.push({ name: source[i].name, color: projectColor(source[i].color) })
  }
  return {
    gid: String(task.gid || ""),
    name: String(task.name || "").trim() || "Untitled task",
    url: String(task.permalink_url || ""),
    dueOn: task.due_on || "",
    due: dueInfo(task.due_on, todayYmd),
    projects: projects,
    subtasks: Number(task.num_subtasks) || 0,
    parentName: task.parent && task.parent.name ? String(task.parent.name) : "",
    milestone: task.resource_subtype === "milestone",
    completed: !!(completedGids && completedGids[task.gid])
  }
}

// Group tasks into My Tasks sections. Section order comes from the sections
// list; sections only seen on tasks follow in order of first appearance.
// Tasks keep the order the API returned them in, which is the list order.
// completedGids marks tasks completed since the snapshot was taken; they stay
// listed (checked) until the next fetch drops them, but no longer count.
function buildSections(snapshot, todayYmd, completedGids) {
  if (!snapshot) return []
  var order = []
  var byGid = {}

  function ensure(section) {
    var gid = String(section.gid || "")
    if (!byGid[gid]) {
      byGid[gid] = { gid: gid, name: String(section.name || FALLBACK_SECTION.name), tasks: [], open: 0 }
      order.push(byGid[gid])
    }
    return byGid[gid]
  }

  var sections = snapshot.sections || []
  for (var i = 0; i < sections.length; i++) if (sections[i]) ensure(sections[i])

  var tasks = snapshot.tasks || []
  for (var j = 0; j < tasks.length; j++) {
    var task = tasks[j]
    if (!task) continue
    var view = taskView(task, todayYmd, completedGids)
    var target = ensure(task.assignee_section || FALLBACK_SECTION)
    target.tasks.push(view)
    if (!view.completed) target.open++
  }
  return order
}

// Rows for the list view: a header per section, then its tasks unless the
// section is collapsed.
function flattenRows(sections, collapsed) {
  var rows = []
  var folded = collapsed || {}
  for (var i = 0; i < sections.length; i++) {
    var section = sections[i]
    var isCollapsed = folded[section.gid] === true
    rows.push({ kind: "section", key: "s:" + section.gid, sectionGid: section.gid, name: section.name, count: section.open, collapsed: isCollapsed })
    if (isCollapsed) continue
    for (var j = 0; j < section.tasks.length; j++)
      rows.push({ kind: "task", key: "t:" + section.tasks[j].gid, sectionGid: section.gid, task: section.tasks[j] })
  }
  return rows
}

function summary(snapshot, todayYmd, completedGids) {
  var result = { open: 0, overdue: 0, dueToday: 0 }
  var tasks = snapshot && snapshot.tasks ? snapshot.tasks : []
  var today = dayNumber(todayYmd)
  for (var i = 0; i < tasks.length; i++) {
    if (!tasks[i] || (completedGids && completedGids[tasks[i].gid])) continue
    result.open++
    var due = dayNumber(tasks[i].due_on)
    if (isNaN(due)) continue
    if (due < today) result.overdue++
    else if (due === today) result.dueToday++
  }
  return result
}

// Sections collapsed on first run, before the user has folded anything.
function defaultCollapsed(sections, names) {
  var wanted = {}
  for (var i = 0; i < (names || []).length; i++) wanted[String(names[i]).toLowerCase()] = true
  var collapsed = {}
  for (var j = 0; j < sections.length; j++)
    if (wanted[sections[j].name.toLowerCase()]) collapsed[sections[j].gid] = true
  return collapsed
}

// Drop completion marks for tasks the snapshot no longer contains; the fetch
// has caught up with them. Tasks in pendingGids keep theirs until their
// write is done.
function pruneCompleted(marks, snapshot, pendingGids) {
  var present = {}
  for (var pending in pendingGids) if (pendingGids[pending]) present[pending] = true
  var tasks = snapshot && snapshot.tasks ? snapshot.tasks : []
  for (var i = 0; i < tasks.length; i++) if (tasks[i]) present[tasks[i].gid] = true
  var next = {}
  for (var gid in marks) if (marks[gid] && present[gid]) next[gid] = true
  return next
}

function relativeTime(iso, nowMs) {
  var then = Date.parse(String(iso || ""))
  if (isNaN(then)) return ""
  var seconds = Math.max(0, Math.round((nowMs - then) / 1000))
  if (seconds < 60) return "just now"
  if (seconds < 3600) return Math.floor(seconds / 60) + "m ago"
  if (seconds < 86400) return Math.floor(seconds / 3600) + "h ago"
  return Math.floor(seconds / 86400) + "d ago"
}

// ASCII-only lowercase, like jq's ascii_downcase in asana-fetch.
function asciiLower(text) {
  return String(text || "").replace(/[A-Z]/g, function(c) { return c.toLowerCase() })
}

// Whether a snapshot shows the workspace the setting asks for, resolved the
// way asana-fetch resolves it: the first workspace whose gid or name (any
// case) matches, or the first workspace for an empty setting. Writes wait
// until this holds, so a task added right after changing the setting cannot
// land in the old workspace. Anything missing counts as no match.
function workspaceMatches(snapshot, setting) {
  if (!snapshot || !snapshot.workspace || !Array.isArray(snapshot.workspaces)) return false
  var want = String(setting || "")
  for (var i = 0; i < snapshot.workspaces.length; i++) {
    var ws = snapshot.workspaces[i]
    if (!ws) continue
    if (want === "" || ws.gid === want || asciiLower(ws.name) === asciiLower(want))
      return ws.gid === snapshot.workspace.gid
  }
  return false
}

// Completion marks are two maps of gid -> true: `shown` is what the list
// displays, `confirmed` what Asana has accepted since the last fetch. A
// toggle changes only `shown`; at most one write per task is in flight, and
// completionWrite says what it should send, if anything.
function completionWrite(gid, shown, confirmed) {
  var want = !!(shown && shown[gid])
  return want === !!(confirmed && confirmed[gid]) ? null : { gid: gid, completed: want }
}

function withMark(marks, gid, on) {
  var next = {}
  for (var key in marks) if (marks[key]) next[key] = true
  if (on) next[gid] = true
  else delete next[gid]
  return next
}

// After writing `completed` for gid: on success Asana has it; on failure the
// list goes back to what Asana has. Either way, completionWrite then tells
// whether a later toggle still needs sending.
function afterCompletionWrite(gid, completed, ok, shown, confirmed) {
  if (ok) return { shown: withMark(shown, gid, !!shown[gid]), confirmed: withMark(confirmed, gid, completed) }
  return { shown: withMark(shown, gid, !!confirmed[gid]), confirmed: withMark(confirmed, gid, !!confirmed[gid]) }
}

function myTasksUrl(snapshot) {
  if (!snapshot || !snapshot.taskListGid) return "https://app.asana.com/"
  return "https://app.asana.com/0/" + snapshot.taskListGid + "/list"
}

if (typeof module !== "undefined") module.exports = {
  parseSnapshot: parseSnapshot, parseTaskResult: parseTaskResult, dayNumber: dayNumber, localYmd: localYmd, dueInfo: dueInfo,
  projectColor: projectColor, taskView: taskView, buildSections: buildSections,
  flattenRows: flattenRows, summary: summary, defaultCollapsed: defaultCollapsed,
  pruneCompleted: pruneCompleted, workspaceMatches: workspaceMatches,
  completionWrite: completionWrite, afterCompletionWrite: afterCompletionWrite,
  relativeTime: relativeTime, myTasksUrl: myTasksUrl
}
