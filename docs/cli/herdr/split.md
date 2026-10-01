# `ed herdr split`

Opens an agent beside the focused pane.

[`ed herdr`](./README.md)

```
ed herdr split <agent> [--side left|right|top|bottom] [--json]
```

`--side` defaults to `right`. From the board, the agent opens in a new tab instead of a split. The agent is an id, a pane id, or a unique title.

## Arguments

| Name | What it is |
| --- | --- |
| `<agent>` | Agent id, pane id, or unique title |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--side <edge>` | `left`, `right`, `top`, `bottom` | `right` | Which side of the focused pane |
| `--json` | flag | off | Emit the layout as JSON |

## Examples

```
ed herdr split w3:p1 --side right
ed herdr split w3:p1 --json
```

## Where to go next

- [`ed herdr move`](./move.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
