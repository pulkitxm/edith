# `ed herdr layout delete`

Deletes one saved layout after a preview.

[`ed herdr`](./README.md)

```
ed herdr layout delete <name> [--yes] [--json]
```

Without `--yes` the command prints the plan and changes nothing. Built-in arrangements are not deleted.

## Arguments

| Name | What it is |
| --- | --- |
| `<name>` | Saved layout name or id |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--yes` | flag | off | Delete after the preview |
| `--json` | flag | off | Emit the plan, or the layout, as JSON |

## Examples

```
ed herdr layout delete Pair
ed herdr layout delete Pair --yes
```

## Where to go next

- [`ed herdr layout ls`](./layout.md)
- [`ed herdr`](./README.md)
- [All `ed` commands](../README.md)
