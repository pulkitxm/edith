# `ed machines workspace ls`

Lists every saved workspace.

Usage:

```
ed machines workspace ls [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments and no filters: `ls` always prints the whole
file, in the order the layouts are stored rather than sorted.

`--json` shape, an array with one object per workspace:

```json
[
  {
    "current": true,
    "id": "A494FD58-CB43-4068-8325-655E86794590",
    "machines": 2,
    "name": "Compare",
    "panes": 2
  },
  {
    "current": false,
    "id": "6C1D0E22-5A77-4B3E-9C48-2F0A7D5B4E31",
    "machines": 1,
    "name": "Asus TUF 7 x3",
    "panes": 3
  }
]
```

`id` is the layout's UUID, which `use`, `rename`, `rm` and `--workspace` all
accept in place of the name. `panes` counts the rectangles; `machines` counts
the distinct machines across every tab of every pane, so a workspace with three
panes on one machine reports `"panes": 3, "machines": 1`. `current` is true for
exactly one row while any workspace exists.

Examples:

```
ed machines workspace ls
ed machines workspace --json
ed machines workspace ls --json | jq -r '.[] | select(.current).name'
```

The table is the same four columns with the last one unlabelled, holding
`current` on one row and nothing on the others:

```
$ ed machines workspace ls
NAME     PANES  MACHINES
Compare  2      2         current
```

Behaviour: `ls` reads the file, writes nothing, posts nothing, and needs neither
the main app nor the menu bar helper. An empty or missing file is not an error:
without `--json` it writes `no workspaces are saved` to stderr, leaves stdout
empty and exits 0, and with `--json` it prints `[]` and exits 0. `ls` and `new`
are the only verbs in this group that do not need a saved workspace already, so
use `ls` when you are probing rather than acting. An unreadable or undecodable
file decodes to an empty store, which is indistinguishable from never having
saved one.

## Where to go next

- [`ed machines workspace`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
