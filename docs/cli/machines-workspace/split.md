# `ed machines workspace split`

Splits a pane in two and points the new one at a machine and a screen.

Usage:

```
ed machines workspace split <pane> <machine> [--side <side>] [--screen <screen>]
                            [--workspace <workspace>] [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<pane>` | integer, 1 to the pane count | required | Which pane to split, counting from 1 as `panes` numbers them. |
| `<machine>` | machine name, ssh alias, id or unambiguous prefix | required | What the new pane points at. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--side` | `left`, `right`, `top`, `bottom` | `right` | Which side of the existing pane the new one goes on. `left` and `right` split horizontally, `top` and `bottom` vertically. |
| `--screen` | `overview`, `processes`, `docker`, `terminal`, `files`, `tools` | `overview` | What the new pane shows. |
| `--workspace` | name, id, or unambiguous name prefix | the current workspace | Which workspace to split a pane in. |
| `--json` | flag | off | Emits one JSON document on stdout. |

`--json` shape: the workspace after the split, in the shape `panes` prints. The
new pane is the focused one.

Examples:

```
ed machines workspace split 1 mini
ed machines workspace split 1 mini --side bottom --screen terminal
ed machines workspace split 2 tuf --screen docker --workspace Fleet
ed machines workspace split 1 mini --json
```

```
$ ed machines workspace split 1 mini --side bottom --screen terminal
split pane 1 to the bottom; 3 panes now
```

Behaviour: this is the pane header's split menu, which offers Split Right and
Split Down and reuses the pane's own target; `ed` reaches all four sides and
makes you say what the new pane points at. The new pane carries exactly one
tab, on the machine and screen you named, and becomes the focused pane. Where
it lands depends on what is already there. If the pane you split already sits
in a split running along the same axis, the newcomer joins as a sibling: it
takes an equal share and every
existing sibling is scaled down to make room, so three panes in a row stay a row
rather than becoming a row containing a row. Otherwise the pane is replaced by a
fresh split of the two, half and half.

`--side left` and `--side top` insert before the pane you named, which means the
new pane takes that pane's number and everything after it shifts up by one. Read
`panes` again rather than assuming the number you split is still the same pane.

Nothing is written until every argument checks out, and they are checked in this
order: the pane number, the machine, the side, then the screen. A bad pane
number exits 3 and says how many the workspace has; an unknown machine exits 3
with the known machines in the hint; a bad side or screen exits 3 and lists the
accepted values:

```
$ ed machines workspace split 7 tuf
error: there is no pane 7 in Compare
hint: it has 2, numbered from 1

$ ed machines workspace split 1 tuf --side sideways
error: no side called sideways
hint: sides: left, right, top, bottom
```

There is no cap on the number of panes and no check that a screen suits the
machine. `--screen docker` on a machine without Docker is accepted here and
fails later, in the pane, where the app's own tab menu would simply not have
offered it.

## Where to go next

- [`ed machines workspace`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
