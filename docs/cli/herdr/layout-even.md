# `ed herdr layout even`

Gives every pane in a tab the same share of the window.

[`ed herdr`](./README.md)

```
ed herdr layout even [--tab <tab>] [--json]
```

This is Even Out in the layout popover.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tab <tab>` | index, id, or title | selected tab | Which tab to even out |
| `--json` | flag | off | Emit the layout as JSON |

## Examples

```
ed herdr layout even --tab 1
ed herdr layout even --json
```

## Where to go next

- [`ed herdr layout apply`](./layout-apply.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
