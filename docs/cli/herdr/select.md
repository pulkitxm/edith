# `ed herdr select`

Shows one Herdr tab in the Edith window, the same way Command-number does.

[`ed herdr`](./README.md)

```
ed herdr select --tab <tab> [--json]
```

The board is tab 0. Hidden tabs keep their terminals, so selecting a tab does
not restart or replay anything.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tab <tab>` | index, id, or title | required | Tab to show |
| `--json` | flag | off | Emit the layout as JSON |

## Examples

```
ed herdr select --tab 2
ed herdr select --tab 0 --json
```

## Where to go next

- [`ed herdr layout`](./layout.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
