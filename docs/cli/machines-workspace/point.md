# `ed machines workspace point`

Points a pane at a different machine, a different screen, or both, without
splitting anything.

Usage:

```
ed machines workspace point <pane> [<machine>] [--screen <screen>]
                            [--workspace <workspace>] [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<pane>` | integer, 1 to the pane count | required | Which pane to retarget, counting from 1. |
| `<machine>` | machine name, ssh alias, id or unambiguous prefix | optional | The machine to point at. Leave it out to change only the screen. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--screen` | `overview`, `processes`, `docker`, `terminal`, `files`, `tools` | unchanged | The screen to show. Leave it out to change only the machine. |
| `--workspace` | name, id, or unambiguous name prefix | the current workspace | Which workspace the pane is in. |
| `--json` | flag | off | Emits one JSON document on stdout. |

At least one of `<machine>` and `--screen` is required. Giving neither exits 1:

```
$ ed machines workspace point 1
error: say a machine, a --screen, or both
```

`--json` shape: the workspace after the change, in the shape `panes` prints.

Examples:

```
ed machines workspace point 1 mini
ed machines workspace point 1 --screen terminal
ed machines workspace point 2 tuf --screen files
ed machines workspace point 1 mini --workspace Fleet --json
```

```
$ ed machines workspace point 2 tuf --screen files
pane 2 now shows files on Asus TUF 7
```

Behaviour: `point` is the Workspace tab strip's machine picker as a command. It
rewrites the selected tab of that pane in place, leaving the tree, the ratios,
the focus and every other tab exactly as they were. On a pane with several tabs
it changes only the one that is showing; there is no way to address the others
from `ed`.

The unchanged half really is left alone: `point 1 mini` keeps whatever screen
the pane was on, and `point 1 --screen terminal` keeps whatever machine it was
pointed at. The confirmation line is assembled from the parts you gave, so with
only a machine it reads `pane 1 now shows  on mini`, with the gap where the
screen would have been.

The pane number is checked first, then the machine, then the screen, and nothing
is written until all three are good. A bad screen exits 3 and names the six:

```
$ ed machines workspace point 1 --screen bogus
error: no screen called bogus
hint: screens: overview, processes, docker, terminal, files, tools
```

## Where to go next

- [`ed machines workspace`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
