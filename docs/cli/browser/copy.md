# `ed browser copy`

Copies a tab address to the clipboard.

[`ed browser`](./README.md)

Usage:

```
ed browser copy [--tab <n>] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

Replaces the general pasteboard with the tab's address.

Examples:

```
ed browser copy
ed browser copy --json
```

See also:

- [`ed browser ls`](./ls.md)
- [`ed browser`](./README.md)
- [`ed`](../README.md)
