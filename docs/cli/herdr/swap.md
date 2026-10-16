# `ed herdr swap`

Swaps two agents that already share a tab.

[`ed herdr`](./README.md)

```
ed herdr swap <agent> <agent> [--json]
```

## Arguments

| Name | What it is |
| --- | --- |
| `<agent>` | Agent id, pane id, or unique title |
| `<agent>` | The other agent in the same tab |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit the layout as JSON |

## Examples

```
ed herdr swap w3:p1 w3:p2
ed herdr swap w3:p1 w3:p2 --json
```

## Where to go next

- [`ed herdr split`](./split.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
