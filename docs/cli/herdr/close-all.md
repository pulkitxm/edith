# `ed herdr close-all`

Closes every Herdr agent tab after a preview.

[`ed herdr`](./README.md)

```
ed herdr close-all [--yes] [--json]
```

The board stays open. Without `--yes` nothing changes.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--yes` | flag | off | Close the tabs after the preview |
| `--json` | flag | off | Emit the plan, or the layout, as JSON |

## Examples

```
ed herdr close-all
ed herdr close-all --yes
```

## Where to go next

- [`ed herdr close-tab`](./close-tab.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
