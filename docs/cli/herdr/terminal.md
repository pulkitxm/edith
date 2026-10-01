# `ed herdr terminal`

Opens a terminal in a Herdr tab.

[`ed herdr`](./README.md)

```
ed herdr terminal [--tab <tab>] [--json]
```

The terminal belongs to the focused agent in that tab and opens on that agent's machine, in that agent's folder. The board opens a terminal on this Mac. This is the same action as Control-Shift-backtick in the space, not `ed machines terminal`.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tab <tab>` | index, id, or title | selected tab | Tab that receives the terminal |
| `--json` | flag | off | Emit the layout as JSON |

## Examples

```
ed herdr terminal --tab 1
ed herdr terminal --json
```

## Where to go next

- [Terminals in agent tabs](./terminals.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
