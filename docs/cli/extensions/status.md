# `ed extensions status`

Summarises extension readiness without changing anything.

```
ed extensions status [<id>] [--json]
```

| Argument | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `id` | one of the sixteen ids, or a defaults key | all extensions | Limit the report to one extension |

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit the complete readiness report |

Without an id, the human form is an ordered table with `ID`, `STATE`, and
`DETAIL` columns. The JSON form is an array in registry order. With an id, the
human form has one row and JSON is one object.

Each JSON report contains `id`, `title`, `verified`, `state`, `checks`, and
`remediation`. An unhealthy extension still exits 0 so scripts can inspect its
complete report.

```
ed extensions status
ed extensions status quinjet
ed extensions status calendar --json
ed extensions status --json | jq '.[] | select(.verified == false)'
```

## Where to go next

- [`ed extensions verify`](./verify.md) for a detailed human report
- [`ed extensions setup`](./setup.md) for noninteractive setup
- [`ed extensions`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
