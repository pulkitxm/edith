# `ed herdr move`

Moves an agent into another tab.

[`ed herdr`](./README.md)

```
ed herdr move <agent> --tab <tab> [--json]
```

This is a drag onto that tab. The destination cannot be the board.

## Arguments

| Name | What it is |
| --- | --- |
| `<agent>` | Agent id, pane id, or unique title |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tab <tab>` | index, id, or title | required | Destination tab |
| `--json` | flag | off | Emit the layout as JSON |

## Examples

```
ed herdr move w3:p1 --tab 2
ed herdr move w3:p1 --tab 2 --json
```

## Where to go next

- [`ed herdr swap`](./swap.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
