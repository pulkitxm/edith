# `ed companion runs`

Lists the background learning runs the scheduler has recorded.

Usage:

```
ed companion runs [--json] [--endpoint <url>] [--limit <n>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | environment or local default | Uses this Companion API base URL. |
| `--limit` | 1 to 200 | 10 | How many to list. |

`--json` shape:

```json
[
  {
    "finishedAt": "2026-08-10T02:03:11Z",
    "id": "b0a3e2c1-9a70-40dd-b1b4-2e0a1f5c7d90",
    "ok": true,
    "startedAt": "2026-08-10T02:00:00Z",
    "steps": [
      { "name": "sync_github", "ok": true },
      { "name": "index", "ok": true },
      { "name": "extract_claims", "ok": true },
      { "name": "corroborate", "ok": true },
      { "name": "reflect", "ok": true }
    ]
  }
]
```

Examples:

```
$ ed companion runs --limit 1
1. 2026-08-10T02:00:00Z  ok  sync_github, index, extract_claims, corroborate, reflect
```

Behaviour: read-only. The companion runs the pipeline once a night at `COMPANION_REFLECT_AT` (02:00 by default) in the backend's local time, or continuously every `COMPANION_SCHEDULE_EVERY_SECONDS` when that testing override is set. Steps that lack their prerequisite, like a missing GitHub token or reasoning provider, record themselves as skipped rather than failing the run. `POST /v1/nightly/run` triggers one manually.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
