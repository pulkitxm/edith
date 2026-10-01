# `ed herdr separate`

Turns one split tab into a tab per agent.

[`ed herdr`](./README.md)

```
ed herdr separate [--tab <tab>] [--json]
```

This is Separate Into Tabs. A tab with one agent is left as it is and the command fails.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tab <tab>` | index, id, or title | selected tab | Split tab to separate |
| `--json` | flag | off | Emit the layout as JSON |

## Examples

```
ed herdr separate --tab 1
ed herdr separate --json
```

## Where to go next

- [`ed herdr gather`](./gather.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
