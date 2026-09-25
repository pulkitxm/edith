# `ed studio info`

[Back to `ed studio`](./README.md)

Shows what a tool does, what it accepts, and every setting it takes with its
type, default and choices. The keys it prints are what `ed studio run --set`
expects.

Usage:

```
ed studio info <tool> [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<tool>` | a tool id from `ed studio tools` | required | The tool to describe. Its title works too. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document with an `options` array. |

Example:

```
ed studio info pdf.compress
```

## Where to go next

- [`ed studio run`](./run.md)
- [All `ed` commands](../README.md)
