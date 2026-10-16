# `ed herdr close-others`

Closes every Herdr tab except one, after a preview.

[`ed herdr`](./README.md)

```
ed herdr close-others [--tab <tab>] [--yes] [--json]
```

Passing the board closes every agent tab. Without `--yes` nothing changes.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tab <tab>` | index, id, or title | selected tab | Tab to keep |
| `--yes` | flag | off | Close the others after the preview |
| `--json` | flag | off | Emit the plan, or the layout, as JSON |

## Examples

```
ed herdr close-others --tab 1
ed herdr close-others --yes
```

## Where to go next

- [`ed herdr close-tab`](./close-tab.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
