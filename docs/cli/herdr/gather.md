# `ed herdr gather`

Gathers every open agent tab into one tab.

[`ed herdr`](./README.md)

```
ed herdr gather [--tab <tab>] [--json]
```

This is Gather All Tabs. Four or more agents land in a grid. Fewer land in columns.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tab <tab>` | index, id, or title | selected tab | Tab that receives every agent |
| `--json` | flag | off | Emit the layout as JSON |

## Examples

```
ed herdr gather --tab 1
ed herdr gather --json
```

## Where to go next

- [`ed herdr separate`](./separate.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
