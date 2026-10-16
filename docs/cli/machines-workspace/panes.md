# `ed machines workspace panes`

Lists the panes in a workspace and what each one shows.

Usage:

```
ed machines workspace panes [--workspace <workspace>] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--workspace` | name, id, or unambiguous name prefix | the current workspace | Which workspace to describe. |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments.

`--json` shape, shared by `panes`, `split`, `close`, `point` and `equalize`, all
five of which print the workspace as it stands after they are done:

```json
{
  "panes": [
    {
      "focused": false,
      "index": 1,
      "tabs": [
        {
          "machine": "Asus TUF 7",
          "screen": "overview",
          "selected": true
        }
      ]
    },
    {
      "focused": true,
      "index": 2,
      "tabs": [
        {
          "machine": "mini",
          "screen": "docker",
          "selected": true
        },
        {
          "machine": "mini",
          "screen": "terminal",
          "selected": false
        }
      ]
    }
  ],
  "workspace": "Compare"
}
```

`index` is the number every pane verb takes. `focused` marks the one pane the
window would have focused, and `selected` marks the one tab in each pane that is
showing. `machine` is the machine's display name looked up from the machine
list, not its id; a pane pointed at a machine that is no longer in the list
reads `"machine": "removed machine"` rather than disappearing.

Examples:

```
ed machines workspace panes
ed machines workspace panes --workspace Compare
ed machines workspace panes --json
ed machines workspace panes --json | jq -r '.panes[] | select(.focused).index'
```

The table is four columns: the pane number, an unlabelled focus column, the
machine, and the screen. It prints one row per pane, showing the selected tab
only, so a pane with three tabs still gets one line:

```
$ ed machines workspace panes
#           MACHINE          SHOWING
1           removed machine  overview
2  focused  Asus TUF 7       overview
```

Behaviour: `panes` reads two files, the workspaces and the machine list, and
writes neither. It needs no app. `--workspace` resolves exactly the way the
positional argument of `use` does, and naming one that does not exist exits 3.
With no workspaces saved at all it exits 4, `--workspace` or not.

`removed machine` in that transcript is the local Mac. The app can put a pane on
This Mac, which is not an entry in the machine list, so `ed` has no name for it
and reports it as removed. That is the state of a default workspace built by the
app, and there is no way to point a pane back at This Mac from `ed`.

## Where to go next

- [`ed machines workspace`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
