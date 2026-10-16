# `ed browser reload`

Reloads a notch browser tab.

[`ed browser`](./README.md)

Usage:

```
ed browser reload [--hard] [--tab <n>] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

`--hard` reloads from the origin.

Examples:

```
ed browser reload
ed browser reload --json
```

See also:

- [`ed browser ls`](./ls.md)
- [`ed browser`](./README.md)
- [`ed`](../README.md)
