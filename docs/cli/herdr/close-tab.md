# `ed herdr close-tab`

Closes one Herdr tab after a preview.

[`ed herdr`](./README.md)

```
ed herdr close-tab [--tab <tab>] [--yes] [--json]
```

Without `--yes` the command prints the plan and changes nothing. `--yes` also stops terminals in that tab without a second prompt. The board cannot be closed.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tab <tab>` | index, id, or title | selected tab | Tab to close |
| `--yes` | flag | off | Close after the preview |
| `--json` | flag | off | Emit the plan, or the layout, as JSON |

## Examples

```
ed herdr close-tab --tab 1
ed herdr close-tab --tab 1 --yes
```

## Where to go next

- [`ed herdr close-others`](./close-others.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
