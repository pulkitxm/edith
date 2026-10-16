# `ed studio tools`

[Back to `ed studio`](./README.md)

Lists Studio's tools with their ids. Tools that need an engine this Mac does not
have yet are marked with what they need.

Usage:

```
ed studio tools [--kind <kind>] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--kind` | `image`, `pdf`, `video`, `audio`, `document`, `presentation`, `spreadsheet`, `archive`, `other` | all | Only tools that accept that kind of file. |
| `--json` | flag | off | Emits one JSON array on stdout. |

Each JSON entry has `id`, `title`, `summary`, `family`, `group`, `inputs`,
`arity` (`each`, `combine 2+` or `none`), `opensEditor`, `available` and, when
something is missing, `needs`.

Examples:

```
ed studio tools --kind pdf
ed studio tools --json | jq -r '.[] | select(.available) | .id'
```

## Where to go next

- [`ed studio info`](./info.md), for a tool's settings
- [All `ed` commands](../README.md)
