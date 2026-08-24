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

Without an id, the human form is an ordered table with `ID`, `READINESS`,
`RUNTIME`, and `DETAIL` columns. The JSON form is an array in registry order.
With an id, the human form has one row and JSON is one object.

Each JSON report contains `id`, `title`, `verified`, `state`, `checks`, and
`remediation`. An unhealthy extension still exits 0 so scripts can inspect its
complete report.

`state.phase` describes setup readiness. `state.runtimePhase` distinguishes an
installed runtime from an uninstalled, empty, loading, unsupported, or failed
runtime. Each check includes its contributing `runtimePhase`, or `null` when it
only affects readiness.

The `adapter.<id>` or `backend.<id>` check is the live feature probe. It reads
the same runtime source the feature uses, such as EventKit, Core Audio,
Service Management, an extension repository, or a verified executable.

```
ed extensions status
ed extensions status quinjet
ed extensions status calendar --json
ed extensions status --json | jq '.[] | select(.verified == false)'
```

## Where to go next

- [`ed extensions verify`](./verify.md) for a detailed human report
- [`ed extensions setup`](./setup.md) for noninteractive setup
- [Extension runtime detection](./runtime-detection.md) for the probe behind
  every extension
- [`ed extensions`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
