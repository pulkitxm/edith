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
| `--endpoint` | URL | resolution order | Uses this Companion API base URL. |
| `--limit` | 1 to 200 | 20 | How many observations to list. |
| `--kind` | stored kind string | all | Only this exact observation kind. |

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

Each item is one observed action: `source` names the connector, `kind` the
action type, `summary` a one-line rendering, and `observedAt` when it happened.
Newest comes first. GitHub produces `commit`, `pull_request`, `issue` and
`review`; file imports add `meeting`, `meeting_moved`, `play` and `watch`;
Edith usage can add its own exact kind strings.

Examples:

```
$ ed companion observations --kind commit --limit 3
#  KIND    SUMMARY                                       OBSERVED
1  commit  pulkitxm/edith 72d2aeb Route audio files ...  2026-08-09T09:12:44Z
```

Behaviour: read-only; an empty record prints `no observations yet`.
Observations are what corroboration checks claims against, so they come from
connectors and usage records, not from notes ingested as episodes. Notion live
sync is the exception among connectors in storage shape: it writes Markdown
episodes, not observation rows.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
