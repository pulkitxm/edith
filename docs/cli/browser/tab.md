# `ed browser tab`

Opens a new notch browser tab.

[`ed browser`](./README.md)

Usage:

```
ed browser tab [address] [--json]
```

Arguments:

| Name | What it is |
| --- | --- |
| `[address]` | Passed through to the notch browser. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

With no address, the tab opens on the search engine home.

Examples:

```
ed browser tab
ed browser tab --json
```

See also:

- [`ed browser ls`](./ls.md)
- [`ed browser`](./README.md)
- [`ed`](../README.md)
