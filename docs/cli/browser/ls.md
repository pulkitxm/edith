# `ed browser ls`

Lists notch browser tabs and Chrome profiles.

[`ed browser`](./README.md)

Usage:

```
ed browser ls [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

Reads the live browser. It does not change tabs.

Examples:

```
ed browser ls
ed browser ls --json
```

See also:

- [`ed browser ls`](./ls.md)
- [`ed browser`](./README.md)
- [`ed`](../README.md)
