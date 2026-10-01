# `ed browser close-right`

Closes notch browser tabs to the right of one tab.

[`ed browser`](./README.md)

Usage:

```
ed browser close-right [--tab <n>] [--yes] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

Prints a plan. `--yes` closes those tabs.

Examples:

```
ed browser close-right
ed browser close-right --json
```

See also:

- [`ed browser ls`](./ls.md)
- [`ed browser`](./README.md)
- [`ed`](../README.md)
