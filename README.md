# Asana for Omarchy

Your Asana **My tasks** list in the Omarchy bar. The bar icon shows how many
tasks are overdue or due today (red when anything is overdue); the popup is
the list view, grouped by your My Tasks sections — *Recently assigned*,
*Today*, *This Week*, whatever custom sections you have — in the order Asana
shows them. Asana's own rules keep moving tasks between sections; the widget
just mirrors the result.

From the popup you can open a task, check it off, and quick-add a new one.

## Install

```bash
omarchy plugin add <git-url-of-this-repo> --enable
# or, from a local checkout:
ln -s "$PWD" ~/.config/omarchy/plugins/tto.asana
omarchy-shell shell rescanPlugins
omarchy plugin enable tto.asana
```

Then sign in: open the popup and choose **Sign in**, or run

```bash
~/.config/omarchy/plugins/tto.asana/bin/asana-login
```

and paste a personal access token from <https://app.asana.com/0/my-apps>.
The token is checked against the API and stored in the GNOME keyring
(`secret-tool`, service `omarchy-asana`). Without a keyring it goes to
`~/.config/omarchy/asana/token` with mode 600. `asana-login --logout` removes
it. `$ASANA_TOKEN` overrides both.

## Using it

| Input | Action |
|---|---|
| Left click | Open / close the popup |
| Middle click | Refresh now |
| Right click | Open My Tasks in the browser |
| `j` `k` / arrows | Move |
| `Enter` / click | Open the task, or fold/unfold a section header |
| `c` / click the circle | Complete the task; again to reopen it |
| `a` / `+` | Quick-add a task (Enter saves, Esc cancels) |
| `h` / `l` | Fold / unfold the current section |
| `r` | Refresh |
| `o` | Open My Tasks in the browser |
| `Esc` | Close |

Completed tasks stay in the list, checked and struck through, so a slip can
be undone with `c`; the next refresh (on closing the popup) drops them. New
tasks are assigned to you, so Asana files them under *Recently assigned*.

Folded sections are remembered in `~/.local/state/omarchy-asana/state.json`.
*Recently assigned* starts folded.

IPC: `omarchy-shell tto.asana toggle|open|close|add|refresh|status`.

## Settings

Inline on the widget's entry in `~/.config/omarchy/shell.json`:

| Key | Default | |
|---|---|---|
| `refreshIntervalSec` | `300` | How often to poll Asana (min 60). |
| `workspace` | `""` | Workspace name or gid; empty uses your first workspace. |
| `badge` | `"due"` | Bar count: `due` (overdue + today), `open` (all open tasks), `none`. |

## How it works

The scripts in `bin/` do all API traffic with curl; `asana-common.sh` holds
the shared token lookup and request handling. `bin/asana-fetch` reads. It resolves your workspace,
finds your user task list, reads its sections, and pages through the
incomplete tasks (`completed_since=now`), each with its `assignee_section`.
It writes one JSON snapshot to `~/.cache/omarchy-asana/tasks.json`, which the
widget watches. The token is handed to curl through a file descriptor, so it
never appears in the process list or in QML. You can run the script by hand
to see exactly what the widget sees:

```bash
bin/asana-fetch | jq '.tasks[] | {name, section: .assignee_section.name, due_on}'
```

`bin/asana-task complete|reopen <gid>` and `bin/asana-task add <workspace-gid>
<name>` do the writes.

| File | Role |
|---|---|
| `Panel.qml` | Bar button, popup layout, keyboard |
| `AsanaService.qml` | The plugin's one service, shared by the widget on every monitor: runs the scripts, watches the cache, fold state, write queue |
| `TaskRow.qml`, `SectionHeader.qml` | List rows |
| `Model.js` | Grouping, counts, date wording, result parsing (plain functions) |

## Development

```bash
npm test                     # Model.js unit tests (node >= 20)
omarchy plugin validate .    # manifest check
omarchy restart shell        # load QML edits
```

Hot reload did not pick up QML edits in a symlinked checkout during
development, so restart the shell after changing `Panel.qml`.
