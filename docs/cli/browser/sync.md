# `ed browser sync`

Syncs the attached Chrome profile into the notch browser.

[`ed browser`](./README.md)

Usage:

```
ed browser sync [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

Starts the same import as the sync button and returns once it is running.

Examples:

```
ed browser sync
ed browser sync --json
```

See also:

- [`ed browser ls`](./ls.md)
- [`ed browser`](./README.md)
- [`ed`](../README.md)
