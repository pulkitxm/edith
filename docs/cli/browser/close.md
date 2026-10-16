# `ed browser close`

Closes a notch browser tab.

[`ed browser`](./README.md)

Usage:

```
ed browser close [--tab <n>] [--yes] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

Prints a plan. `--yes` closes the tab. The last tab is replaced by a new one.

Examples:

```
ed browser close
ed browser close --json
```

See also:

- [`ed browser ls`](./ls.md)
- [`ed browser`](./README.md)
- [`ed`](../README.md)
