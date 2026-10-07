const test = require('node:test')
const assert = require('node:assert/strict')
const M = require('../Model.js')

const TODAY = '2026-09-28' // a Monday

const snapshot = {
  taskListGid: '900',
  sections: [
    { gid: '1', name: 'Recently assigned' },
    { gid: '2', name: 'Today' },
    { gid: '3', name: 'This Week' },
    { gid: '4', name: 'Later' }
  ],
  tasks: [
    { gid: 'a', name: 'End of Month Checks', due_on: '2026-08-28', assignee_section: { gid: '2', name: 'Today' }, projects: [], num_subtasks: 2 },
    { gid: 'b', name: 'Zip folders', due_on: '2026-09-30', assignee_section: { gid: '3', name: 'This Week' }, projects: [{ gid: 'p', name: 'Weleda | Backlog', color: 'orange' }] },
    { gid: 'c', name: 'VAT return', due_on: '2026-10-07', assignee_section: { gid: '1', name: 'Recently assigned' }, projects: [] },
    { gid: 'd', name: 'Due today', due_on: TODAY, assignee_section: { gid: '2', name: 'Today' }, projects: [] },
    { gid: 'e', name: '  ', assignee_section: { gid: '5', name: 'Inbox' }, parent: { name: 'Parent task' }, resource_subtype: 'milestone' }
  ]
}

test('parseSnapshot distinguishes data, errors and garbage', () => {
  assert.equal(M.parseSnapshot('').snapshot, null)
  assert.equal(M.parseSnapshot('').error, null)
  assert.equal(M.parseSnapshot(JSON.stringify(snapshot)).snapshot.tasks.length, 5)
  assert.deepEqual(M.parseSnapshot('{"error":{"kind":"auth","message":"nope"}}').error, { kind: 'auth', message: 'nope' })
  assert.equal(M.parseSnapshot('{not json').error.kind, 'api')
  assert.equal(M.parseSnapshot('{"foo":1}').error.kind, 'api')
})

test('dueInfo words dates like the Asana list view', () => {
  assert.deepEqual(M.dueInfo(TODAY, TODAY), { label: 'Today', tone: 'soon' })
  assert.deepEqual(M.dueInfo('2026-09-29', TODAY), { label: 'Tomorrow', tone: 'soon' })
  assert.deepEqual(M.dueInfo('2026-09-27', TODAY), { label: 'Yesterday', tone: 'overdue' })
  assert.deepEqual(M.dueInfo('2026-09-30', TODAY), { label: 'Wednesday', tone: '' })
  assert.deepEqual(M.dueInfo('2026-10-04', TODAY), { label: 'Sunday', tone: '' })
  assert.deepEqual(M.dueInfo('2026-10-05', TODAY), { label: 'Oct 5', tone: '' })
  assert.deepEqual(M.dueInfo('2026-08-28', TODAY), { label: 'Aug 28', tone: 'overdue' })
  assert.deepEqual(M.dueInfo('2025-03-27', TODAY), { label: 'Mar 27, 2025', tone: 'overdue' })
  assert.deepEqual(M.dueInfo(null, TODAY), { label: '', tone: '' })
  assert.deepEqual(M.dueInfo('garbage', TODAY), { label: '', tone: '' })
})

test('buildSections keeps section order, includes empty and unlisted sections', () => {
  const sections = M.buildSections(snapshot, TODAY)
  assert.deepEqual(sections.map(s => s.name), ['Recently assigned', 'Today', 'This Week', 'Later', 'Inbox'])
  assert.deepEqual(sections.map(s => s.tasks.length), [1, 2, 1, 0, 1])
  assert.deepEqual(sections[1].tasks.map(t => t.gid), ['a', 'd'])
})

test('buildSections falls back to first-appearance order without a section list', () => {
  const sections = M.buildSections({ tasks: snapshot.tasks }, TODAY)
  assert.deepEqual(sections.map(s => s.name), ['Today', 'This Week', 'Recently assigned', 'Inbox'])
  assert.deepEqual(M.buildSections({ tasks: [{ gid: 'x', name: 'x' }] }, TODAY)[0].name, 'Other')
  assert.deepEqual(M.buildSections(null, TODAY), [])
})

test('taskView normalises a task for display', () => {
  const [, today, week, , inbox] = M.buildSections(snapshot, TODAY)
  assert.equal(today.tasks[0].subtasks, 2)
  assert.equal(today.tasks[0].due.tone, 'overdue')
  assert.deepEqual(week.tasks[0].projects, [{ name: 'Weleda | Backlog', color: '#f59c5a' }])
  assert.equal(inbox.tasks[0].name, 'Untitled task')
  assert.equal(inbox.tasks[0].parentName, 'Parent task')
  assert.equal(inbox.tasks[0].milestone, true)
})

test('flattenRows hides the tasks of collapsed sections but keeps the header', () => {
  const sections = M.buildSections(snapshot, TODAY)
  const rows = M.flattenRows(sections, { '1': true })
  assert.deepEqual(rows.map(r => r.key), ['s:1', 's:2', 't:a', 't:d', 's:3', 't:b', 's:4', 's:5', 't:e'])
  assert.equal(rows[0].collapsed, true)
  assert.equal(rows[0].count, 1)
})

test('summary counts open, overdue and due-today tasks', () => {
  assert.deepEqual(M.summary(snapshot, TODAY), { open: 5, overdue: 1, dueToday: 1 })
  assert.deepEqual(M.summary(null, TODAY), { open: 0, overdue: 0, dueToday: 0 })
})

test('defaultCollapsed matches section names case-insensitively', () => {
  const sections = M.buildSections(snapshot, TODAY)
  assert.deepEqual(M.defaultCollapsed(sections, ['recently assigned']), { '1': true })
  assert.deepEqual(M.defaultCollapsed(sections, []), {})
})

test('relativeTime and projectColor', () => {
  const now = Date.parse('2026-09-28T12:00:00Z')
  assert.equal(M.relativeTime('2026-09-28T11:59:30Z', now), 'just now')
  assert.equal(M.relativeTime('2026-09-28T11:55:00Z', now), '5m ago')
  assert.equal(M.relativeTime('2026-09-28T09:00:00Z', now), '3h ago')
  assert.equal(M.relativeTime('nope', now), '')
  assert.equal(M.projectColor('none'), '')
  assert.equal(M.projectColor('blue'), '#7a9ff5')
  assert.equal(M.myTasksUrl(snapshot), 'https://app.asana.com/0/900/list')
})

test('completed tasks stay listed but leave the counts', () => {
  const done = { a: true }
  const sections = M.buildSections(snapshot, TODAY, done)
  const today = sections[1]
  assert.equal(today.tasks[0].completed, true)
  assert.equal(today.tasks[1].completed, false)
  assert.equal(today.open, 1)
  assert.equal(M.flattenRows(sections, {}).find(r => r.key === 's:2').count, 1)
  assert.deepEqual(M.summary(snapshot, TODAY, done), { open: 4, overdue: 0, dueToday: 1 })
})

test('pruneCompleted forgets tasks the snapshot dropped', () => {
  assert.deepEqual(M.pruneCompleted({ a: true, gone: true, b: false }, snapshot), { a: true })
  assert.deepEqual(M.pruneCompleted({ a: true }, null), {})
})

test('parseTaskResult accepts a task, relays errors, rejects garbage', () => {
  assert.deepEqual(M.parseTaskResult('{"task":{"gid":"1","name":"x","completed":true}}').task, { gid: '1', name: 'x', completed: true })
  assert.deepEqual(M.parseTaskResult('{"error":{"kind":"auth","message":"no"}}').error, { kind: 'auth', message: 'no' })
  assert.equal(M.parseTaskResult('').error.kind, 'api')
  assert.equal(M.parseTaskResult('{"task":{}}').error.kind, 'api')
})

test('workspaceMatches follows how asana-fetch picks the workspace', () => {
  const snap = {
    workspace: { gid: '2', name: 'Acme Studio' },
    workspaces: [{ gid: '1', name: 'Personal' }, { gid: '2', name: 'Acme Studio' }]
  }
  assert.equal(M.workspaceMatches(snap, '2'), true)
  assert.equal(M.workspaceMatches(snap, 'acme studio'), true)
  assert.equal(M.workspaceMatches(snap, '1'), false)
  assert.equal(M.workspaceMatches(snap, 'Personal'), false)
  assert.equal(M.workspaceMatches(snap, ''), false)
  assert.equal(M.workspaceMatches({ ...snap, workspace: { gid: '1', name: 'Personal' } }, ''), true)
  assert.equal(M.workspaceMatches(null, ''), false)
})

test('workspaceMatches fails closed and follows asana-fetch on duplicate names', () => {
  assert.equal(M.workspaceMatches({ workspace: { gid: '1', name: 'A' } }, ''), false)
  assert.equal(M.workspaceMatches({ workspace: { gid: '1', name: 'A' }, workspaces: [] }, ''), false)
  const dup = { workspaces: [{ gid: '1', name: 'Team' }, { gid: '2', name: 'Team' }] }
  assert.equal(M.workspaceMatches({ ...dup, workspace: { gid: '1', name: 'Team' } }, 'team'), true)
  assert.equal(M.workspaceMatches({ ...dup, workspace: { gid: '2', name: 'Team' } }, 'team'), false)
  assert.equal(M.workspaceMatches({ ...dup, workspace: { gid: '2', name: 'Team' } }, '2'), true)
})

// Plays the service's completion rules: one write per task in flight, a
// toggle only flips the shown mark, results go through afterCompletionWrite.
function completionRun(steps) {
  let shown = {}, confirmed = {}, inFlight = null
  const sent = []
  const send = () => {
    const w = M.completionWrite('t', shown, confirmed)
    if (w) { inFlight = w; sent.push(w.completed ? 'complete' : 'reopen') }
  }
  for (const step of steps) {
    if (step === 'refresh') {
      // A fetch that no longer lists the task (Asana already completed it).
      const pending = inFlight ? { t: true } : {}
      shown = M.pruneCompleted(shown, { tasks: [] }, pending)
      confirmed = M.pruneCompleted(confirmed, { tasks: [] }, pending)
    } else if (step === 'toggle') {
      shown = shown.t ? {} : { t: true }
      if (!inFlight) send()
    } else {
      const marks = M.afterCompletionWrite('t', inFlight.completed, step === 'ok', shown, confirmed)
      shown = marks.shown; confirmed = marks.confirmed; inFlight = null
      send()
    }
  }
  return { shown: !!shown.t, confirmed: !!confirmed.t, sent, inFlight: !!inFlight }
}

test('completion writes: a quick undo is sent after the first write', () => {
  assert.deepEqual(completionRun(['toggle', 'toggle', 'ok', 'ok']),
    { shown: false, confirmed: false, sent: ['complete', 'reopen'], inFlight: false })
})

test('completion writes: two failures leave the task open, as Asana has it', () => {
  assert.deepEqual(completionRun(['toggle', 'toggle', 'fail']),
    { shown: false, confirmed: false, sent: ['complete'], inFlight: false })
  assert.deepEqual(completionRun(['toggle', 'fail']),
    { shown: false, confirmed: false, sent: ['complete'], inFlight: false })
})

test('completion writes: a failed undo keeps the confirmed completion', () => {
  assert.deepEqual(completionRun(['toggle', 'toggle', 'ok', 'fail']),
    { shown: true, confirmed: true, sent: ['complete', 'reopen'], inFlight: false })
})

test('completion writes: toggling back before anything is sent sends nothing more', () => {
  assert.deepEqual(completionRun(['toggle', 'toggle', 'toggle', 'ok']),
    { shown: true, confirmed: true, sent: ['complete'], inFlight: false })
  assert.equal(M.completionWrite('t', {}, {}), null)
})

test('completion writes: a refresh that lands before the write result sends no reopen', () => {
  assert.deepEqual(completionRun(['toggle', 'refresh', 'ok']),
    { shown: true, confirmed: true, sent: ['complete'], inFlight: false })
  assert.deepEqual(completionRun(['toggle', 'refresh', 'ok', 'refresh']),
    { shown: false, confirmed: false, sent: ['complete'], inFlight: false })
  // Undone before the result: Asana has the completion, the reopen follows.
  assert.deepEqual(completionRun(['toggle', 'toggle', 'refresh', 'ok']),
    { shown: false, confirmed: true, sent: ['complete', 'reopen'], inFlight: true })
})

test('pruneCompleted keeps marks for tasks with a pending write', () => {
  assert.deepEqual(M.pruneCompleted({ a: true, gone: true }, snapshot, { gone: true }), { a: true, gone: true })
})
