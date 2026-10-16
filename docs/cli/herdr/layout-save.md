# `ed herdr layout save`

Saves the pane geometry of a split tab under a name.

[`ed herdr`](./README.md)

```
ed herdr layout save <name> [--tab <tab>] [--json]
```

The tab needs at least two agents. A saved layout with the same shape is replaced.

## Arguments

| Name | What it is |
| --- | --- |
| `<name>` | Name stored for this layout |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tab <tab>` | index, id, or title | selected tab | Which tab to save |
| `--json` | flag | off | Emit the layout as JSON |

## Examples

```
ed herdr layout save Pair --tab 1
ed herdr layout save Pair --json
```

## Where to go next

- [`ed herdr layout apply`](./layout-apply.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
