# `ed herdr layout`

Lists the tabs, saved layouts, and agent terminals in the open Edith window.

[`ed herdr`](./README.md)

```
ed herdr layout ls [--json]
```

`ed herdr layout` runs `ls`. `list` is an alias for `ls`. Index 0 is the board. Agent tabs start at 1. A selected row is marked with `*`.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit one JSON document on stdout |

The JSON object has `agents`, `arrangements`, `message`, `selected`, `tabs`, and `terminals`. This command needs the Edith window. It exits 4 when that window is not open.

## Examples

```
ed herdr layout ls
ed herdr layout ls --json
```

## Where to go next

- [`ed herdr layout save`](./layout-save.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
