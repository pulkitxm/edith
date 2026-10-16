# `ed herdr close-right`

Closes Herdr tabs to the right of one tab, after a preview.

[`ed herdr`](./README.md)

```
ed herdr close-right [--tab <tab>] [--yes] [--json]
```

Without `--yes` nothing changes.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tab <tab>` | index, id, or title | selected tab | Last tab that stays |
| `--yes` | flag | off | Close the tabs after the preview |
| `--json` | flag | off | Emit the plan, or the layout, as JSON |

## Examples

```
ed herdr close-right --tab 1
ed herdr close-right --yes
```

## Where to go next

- [`ed herdr close-all`](./close-all.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
