# `ed browser close-others`

Closes every notch browser tab except one.

[`ed browser`](./README.md)

Usage:

```
ed browser close-others [--tab <n>] [--yes] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

Prints a plan. `--yes` closes the other tabs.

Examples:

```
ed browser close-others
ed browser close-others --json
```

See also:

- [`ed browser ls`](./ls.md)
- [`ed browser`](./README.md)
- [`ed`](../README.md)
