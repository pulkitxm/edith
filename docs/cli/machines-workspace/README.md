# `ed machines workspace`

`ed machines workspace` reads and writes the saved multi-pane layouts the app's
Workspace view shows. Reach for it when you want an arrangement of machines and
screens ready before the window opens, when a script should retarget a pane at
whichever machine it just built, or when you want to know what the window is
about to show without opening it.

## The model

A **workspace** is a named layout: an id, a tree of panes, the id of the focused
pane, and optionally the id of a maximized one. Several workspaces can be saved
at once and exactly one of them is current, which is the one the view opens on
and the one every pane verb here acts on unless `--workspace` names another.

A **pane** is one rectangle in that tree. It holds one or more tabs and
remembers which of them is selected. A **tab** is a target: one machine and one
screen. `ed` builds panes with exactly one tab, and it only ever reads or writes
the selected one; a pane with several tabs came from the app's tab strip, and
`ed` reports all of them but adds and removes none.

Panes are held together by **splits**. A split has an axis, horizontal or
vertical, an ordered list of children, and a ratio for each child. `ed` never
sets a ratio by hand: `split` gives the new pane an equal share and rescales its
siblings, and `equalize` levels every split in the tree.

A **screen** is what a pane draws. There are six, and every one of them is
accepted anywhere a `--screen` goes:

| Screen | What the pane shows |
| --- | --- |
| `overview` | The machine's overview: CPU, memory, disks, uptime. |
| `processes` | The process list. |
| `docker` | The Docker console: containers, images, volumes. |
| `terminal` | A terminal on the machine. |
| `files` | The Finder pane for that machine. |
| `tools` | The Tools tab: port forwards, snippets, services and power. |

Panes are numbered from 1 in the order the tree flattens: depth first, children
in order, so left to right inside a horizontal split and top to bottom inside a
vertical one. The number is a position rather than an id: every split inserts a
pane into that order and pushes the rest along, every close takes one out, and
splitting to the left of or above pane 1 makes the new pane pane 1.

```
Compare, before                     Compare, after `split 1 tuf --side bottom`
1  Asus TUF 7   overview            1  Asus TUF 7   overview
2  mini         docker              2  Asus TUF 7   overview
                                    3  mini         docker
```

The whole set lives in one file,
`~/Library/Application Support/Edith/machines/workspaces.json`, holding the list
of layouts and the id of the current one. Nothing in this group talks to Edith
for its data, so every verb works whether or not the app is running. Each write
does post the app's `machinesChanged` notification afterwards, and a running
Edith does not use it to reload workspaces, which is the one thing worth reading
[Notes and gotchas](#notes-and-gotchas) for before you script against a machine
that has Edith open.

## At a glance

| Command | What it does |
| --- | --- |
| `ed machines workspace` | Runs `ed machines workspace ls`, which is the default subcommand. |
| `ed machines workspace ls` | Lists the saved workspaces, their pane and machine counts, and which is current. |
| `ed machines workspace use <workspace>` | Makes one workspace the current one. |
| `ed machines workspace new <machines>...` | Builds a workspace with one pane per machine, tiled side by side. |
| `ed machines workspace rename <workspace> <name>` | Renames a workspace, leaving which one is current alone. |
| `ed machines workspace rm <workspace>` | Forgets a workspace. |
| `ed machines workspace panes` | Lists the panes in a workspace, what each shows, and which is focused. |
| `ed machines workspace split <pane> <machine>` | Splits a pane and points the new one at a machine and a screen. |
| `ed machines workspace close <pane>` | Closes a pane. |
| `ed machines workspace point <pane> [<machine>]` | Retargets a pane's selected tab without splitting anything. |
| `ed machines workspace equalize` | Evens out every split in the workspace. |

`ed machines workspaces` is the same group under a second name, and the verbs
carry aliases too: `list` for `ls`, `remove` for `rm`, and `even` for
`equalize`. `ed machines workspace` with nothing after it runs `ls`, including
its flags, so `ed machines workspace --json` is
`ed machines workspace ls --json`.

Five verbs take `--workspace` to act on a layout other than the current one:
`panes`, `split`, `close`, `point` and `equalize`. The three that operate on a
whole workspace, `use`, `rename` and `rm`, take it as a positional argument
instead, and `new` takes none because it is making one.

## Commands

- [`ed machines workspace ls`](./ls.md)
- [`ed machines workspace use`](./use.md)
- [`ed machines workspace new`](./new.md)
- [`ed machines workspace rename`](./rename.md)
- [`ed machines workspace rm`](./rm.md)
- [`ed machines workspace panes`](./panes.md)
- [`ed machines workspace split`](./split.md)
- [`ed machines workspace close`](./close.md)
- [`ed machines workspace point`](./point.md)
- [`ed machines workspace equalize`](./equalize.md)

## Exit codes

| Code | When this group produces it |
| --- | --- |
| 0 | The listing or the change succeeded. Also `ls` on an empty store, `equalize` on a single-pane workspace, and `--help` on the group or any verb. |
| 1 | The file could not be written, with the system's own description in the message. Also `close` on the last pane, `rename` to a blank name, `point` with neither a machine nor a `--screen`, and `new` with a machine list the parser let through empty. |
| 2 | The command line was wrong in ArgumentParser's own terms: an unknown flag, a missing `<workspace>`, `<name>`, `<pane>` or `<machines>`, or a `<pane>` that is not an integer. |
| 3 | Something you named does not exist: a workspace name or prefix that matches none or several, a pane number below 1 or above the count, a `--screen` or `--side` outside the accepted values, or a machine name that matches none or several. |
| 4 | No workspaces are saved at all, and the verb needs one. Every verb except `ls` and `new` produces this on an empty store. |

Exit 4 here never means the app is missing. Nothing in this group waits on
Edith, and the only thing that reports itself unavailable is an empty store,
which you fix with `ed machines workspace new` rather than by opening the app.

## Notes and gotchas

- A running Edith holds the workspace file in memory and does not reload it.
  The Workspace view reads `workspaces.json` once, when it is first built, and
  writes its whole in-memory store back on every change it makes. The
  `machinesChanged` notification `ed` posts after each write is observed by the
  machine list, not by the workspace model, so a layout built from the CLI
  while the app is open does not appear, and the app's next pane change saves
  its older copy over yours. Do CLI workspace work while Edith is closed, or
  quit and reopen it to pick up what you wrote.
- The app's Layout menu replaces the whole file. Choosing Compare two machines,
  Docker everywhere, Terminal grid, Files side by side or Single pane does not
  add a workspace: it sets the saved list to exactly that one layout. Every
  workspace `ed` saved is gone at that point. `ed machines workspace new`
  builds the same kind of layout and appends it instead.
- This Mac cannot be reached from here. The app's machine list starts with a
  built-in local machine that is not in `machines.json`, so `MachineResolver`
  never finds it and `panes` prints `removed machine` for any pane pointing at
  it. A workspace the app built for you almost certainly contains one.
- `tools` is a valid `--screen` on `new`, `split` and `point`, even though the
  help text for `new --screen` lists only five values. The hint you get from a
  bad screen is generated from the enum and lists all six in their declared
  order: `overview, processes, docker, terminal, files, tools`.
- Screen availability is not checked against the machine. The app hides
  `docker` for a machine with no Docker daemon and offers only `overview`,
  `processes`, `files` and `terminal` for This Mac; `ed` accepts anything and
  lets the pane deal with it.
- Workspace names are not unique, and only `rename` checks one at all: it trims
  and refuses a blank, while `new --name` stores whatever you pass, whitespace
  included. Two workspaces can share a name; lookups take the first, so the
  second is addressable only by its id. `ls --json` is where you get ids.
- Workspace lookup is name, then id, then unique prefix, and it is
  case-insensitive throughout. There is no ssh-alias step here, unlike machine
  lookup, because a workspace has only the one name.
- Which workspace is current is stored as an id, and an absent or dangling one
  falls back to the first in the file. `ls` shows that fallback as current;
  `rename` reports `"current": false` for it, because it reads the stored
  pointer rather than the effective one. One `use` makes them agree.
- `new` switches you to the workspace it made. `use` switches you deliberately.
  Nothing else does: `rename` restores the pointer it found, and the five pane
  verbs preserve it, so editing another workspace through `--workspace` leaves
  you where you were. The one exception is a store that has never had a current
  workspace, where a pane edit makes the edited layout current.
- Pane numbers are positions in a flattened tree, not ids, and both `split` and
  `close` can renumber panes other than the one you named. Anything that
  touches more than one pane should re-read `panes` between steps, or work from
  the highest number down.
- `ed` writes one tab per pane and reads the selected tab only. Extra tabs come
  from the app, survive everything here, and show up in `panes --json`. There is
  no verb to add, close, select or reorder a tab, and none to set focus or to
  maximize a pane; `split` and `close` move focus as a side effect and that is
  the whole of it.
- Every mutating verb rewrites the entire file atomically from what it just
  read. Two `ed` processes editing different workspaces at the same moment
  leave only the later change, and a running app counts as a third writer.
- The file on disk is compact JSON with keys in whatever order the encoder
  produced. The pretty, alphabetically sorted documents `--json` prints are
  generated fresh and are not what is stored, so do not diff one against the
  other.
- The layout also carries a `maximized` pane id, which `ed` never sets and only
  ever clears, when the maximized pane is the one you close. Split ratios are
  the other stored value no `--json` document reports: `split` and `equalize`
  set them in bulk, dragging a divider in the window sets one by hand, and
  nothing here reads them back to you.
- Completion knows the verbs and the machine slots. `ed machines workspace
  <TAB>` offers the ten subcommands, and the machine argument of `split` and
  `point` and the machine list of `new` complete against your machines. The
  workspace slots of `use`, `rename` and `rm` complete nothing, and neither do
  pane numbers or the values of `--workspace`, `--screen` and `--side`. Writing
  an option before the positionals, as in `split --screen docker 1 <TAB>`, also
  costs you the machine completion, because the option's value is counted as a
  positional when the slot is worked out.
- `--help` works on the group and on all ten verbs, prints on stdout and exits
  0. `--version` is inherited from the root and works on any of them.

## Where to go next

- [`ed machines`](../machines/README.md), for the machine list every pane points into,
  and for adding the machines you want panes for.
- [`ed machines files`](../machines-files/README.md) and
  [`ed machines docker`](../machines-docker/README.md), the command line forms of two of
  the screens a pane can show.
- [Running commands on a machine](../machines-remote/README.md), which is the terminal
  screen's counterpart.
- [Conventions and contracts](../conventions.md), for the exit code table and the
  `--json` guarantee in full.
- [All `ed` commands](../README.md).
