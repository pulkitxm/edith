# `ed browser detach`

Detaches the Chrome profile and clears its browser data.

[`ed browser`](./README.md)

Usage:

```
ed browser detach [--yes] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

Prints a plan. `--yes` detaches the profile and removes its website data.

Examples:

```
ed browser detach
ed browser detach --json
```

See also:

- [`ed browser ls`](./ls.md)
- [`ed browser`](./README.md)
- [`ed`](../README.md)
