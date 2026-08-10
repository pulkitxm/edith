# `ed machines files undo`

Undoes the last move or rename made in an open Files pane for that machine.

```
ed machines files undo <machine> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Whose Files pane to ask. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "machine": "Asus TUF 7",
  "undone": true,
  "what": "Undo Rename"
}
```

```
ed machines files undo tuf
ed machines files undo tuf --json
```

This is the only verb in the group that does not touch SSH. The machine name is
resolved against Edith's own machine list, and everything after that happens
over the app's notification bus: `ed` posts a request carrying the machine's id,
then waits up to 20 seconds for the answer, printing `waiting for Edith to
answer...` on stderr once a second has passed.

**What is undoable.** Exactly two operations, and only when a Files pane
performed them and they succeeded: a rename committed in the pane, and a move
within the machine, which is a drag onto a folder or a cut and paste. The step
is labelled `Rename` or `Move` accordingly.

**What is not.** Copies, duplicates, new folders, trashes, deletes, uploads,
downloads and transfers between machines are never recorded. Neither is anything
`ed` itself did: `ed machines files mv` and `ed machines files rename` do not
join the history, so reverse those with another `mv` or `rename`, which is the
same command the pane would have run.

**How far back.** Each pane keeps its last 20 steps and drops the oldest beyond
that. One invocation pops one step, the most recent, so walk backwards by
running the command again.

**For how long.** As long as the pane is there. The stack lives in memory and is
never written to disk, so closing the pane, pointing it at another screen,
closing the workspace tab or quitting Edith all discard it. Nothing expires on a
timer, and nothing survives a relaunch.

**Which window.** Only a Files pane inside Edith's main window registers itself
as undoable. A standalone Finder window, the kind the Files button on a machine
opens, keeps a private stack that its own Command-Z drives and that `ed` cannot
reach. When several panes are open for one machine, `ed` gets whichever of them
has something on its stack, not necessarily the frontmost.

The reversal replays the step's moves backwards using the same guarded rename
`ed machines files rename` uses, so an undo whose original name has been taken
in the meantime stops rather than overwriting, and it stops at the first move
that fails.

Three things make this exit 4. Edith's main window not being open at all, which
is checked as soon as the name has resolved, so a name that matches nothing
still exits 3 ahead of it:

```
$ ed machines files undo tuf
error: the undo history lives in an open Finder window, and Edith is not running
hint: open Edith and its Files window for Asus TUF 7, then retry
```

A running app with nothing to give back:

```
$ ed machines files undo tuf
error: no Finder window for Asus TUF 7 has anything to undo
hint: open one with the Files tab, or reverse it with `ed machines files mv`
```

And an app that never answers within the 20 seconds, which is reported as
`Edith did not answer for undoing a file change in time`, or as
`Edith is not running, so it cannot answer for undoing a file change` when the
menu bar helper has gone away in the meantime.

On success the human line is `undid <label> on <machine>`. The label is the
pane's own menu title, which already starts with the word Undo, so the line
reads a little oddly and the JSON does too:

```
$ ed machines files undo tuf
undid Undo Rename on Asus TUF 7
```

The only values `what` takes are `Undo Rename`, `Undo Move` and, if the pane has
no title to give, `the last change`.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
