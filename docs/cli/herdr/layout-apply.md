# `ed herdr layout apply`

Applies a built-in arrangement or a saved layout to one tab.

[`ed herdr`](./README.md)

```
ed herdr layout apply <name> [--tab <tab>] [--json]
```

Built-in names are `columns`, `rows`, `grid`, `tallGrid`, `focusLeft`, `focusRight`, `focusTop`, `focusBottom`, `focusCenter`, `twoColumns`, and `twoRows`. Titles such as `Side by Side` work too. The arrangement has to fit the number of agents in the tab.

## Arguments

| Name | What it is |
| --- | --- |
| `<name>` | Built-in arrangement or saved layout |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tab <tab>` | index, id, or title | selected tab | Which tab to arrange |
| `--json` | flag | off | Emit the layout as JSON |

## Examples

```
ed herdr layout apply columns --tab 1
ed herdr layout apply Pair --json
```

## Where to go next

- [`ed herdr layout save`](./layout-save.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
