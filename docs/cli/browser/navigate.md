# `ed browser navigate`

Loads an address in a notch browser tab.

[`ed browser`](./README.md)

Usage:

```
ed browser navigate <address> [--tab <n>] [--json]
```

Arguments:

| Name | What it is |
| --- | --- |
| `<address>` | Passed through to the notch browser. |


Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

A value with spaces is searched the way the address bar searches.

Examples:

```
ed browser navigate <address>
ed browser navigate --json
```

See also:

- [`ed browser ls`](./ls.md)
- [`ed browser`](./README.md)
- [`ed`](../README.md)
