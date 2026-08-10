# `ed companion observations`

Lists the behavioural record the connectors have gathered.

Usage:

```
ed companion observations [--json] [--endpoint <url>] [--limit <n>] [--kind <kind>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | environment or local default | Uses this Companion API base URL. |
| `--limit` | 1 to 200 | 20 | How many observations to list. |
| `--kind` | `commit`, `pull_request`, `issue`, `review` | all | Only this observation kind. |

`--json` shape:

```json
[
  {
    "id": "0d5c53a4-52f0-4be3-a121-c7f3ac53f7de",
    "kind": "commit",
    "observedAt": "2026-08-09T09:12:44Z",
    "source": "github",
    "summary": "pulkitxm/edith 72d2aeb Route audio files through ed companion ingest"
  }
]
```

Each item is one observed action: `source` names the connector, `kind` the action type, `summary` a one-line rendering, and `observedAt` when it happened. Newest first.

Examples:

```
$ ed companion observations --kind commit --limit 3
#  KIND    SUMMARY                                       OBSERVED
1  commit  pulkitxm/edith 72d2aeb Route audio files ...  2026-08-09T09:12:44Z
```

Behaviour: read-only; an empty record prints a quiet line. Observations are what corroboration will check your claims against, so they never come from anything you wrote for the companion.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
