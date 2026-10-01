# `ed browser profile`

Attaches a Chrome profile to the notch browser.

[`ed browser`](./README.md)

Usage:

```
ed browser profile <name> [--json]
```

Arguments:

| Name | What it is |
| --- | --- |
| `<name>` | Passed through to the notch browser. |


Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

Matches a profile name or directory, then starts importing it.

Examples:

```
ed browser profile <name>
ed browser profile --json
```

See also:

- [`ed browser ls`](./ls.md)
- [`ed browser`](./README.md)
- [`ed`](../README.md)
