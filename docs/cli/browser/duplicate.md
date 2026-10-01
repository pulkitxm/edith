# `ed browser duplicate`

Duplicates a notch browser tab.

[`ed browser`](./README.md)

Usage:

```
ed browser duplicate [--tab <n>] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

Opens the same address in a new tab beside it.

Examples:

```
ed browser duplicate
ed browser duplicate --json
```

See also:

- [`ed browser ls`](./ls.md)
- [`ed browser`](./README.md)
- [`ed`](../README.md)
