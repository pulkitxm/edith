# `ed companion episodes`

Lists the most recent episodes ordered by occurrence time.

Usage:

```
ed companion episodes [--limit <n>] [--json] [--endpoint <url>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--limit` | positive integer | `20` | Asks for this many recent episodes. The API caps it at 200. |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | resolution order | Uses this Companion API base URL. |

`--json` shape:

```json
[
  {
    "id": "5d4c0ebf-1086-46fb-ab93-dd325ed197f3",
    "kind": "md",
    "occurredAt": "2026-08-09T06:30:00.000Z",
    "sha256": "a46b0c249b09d97a9a2eeb66e995fe56d6513fbb80a4f711f846d6b92e98a1e3",
    "title": "Planning notes"
  }
]
```

Each item has its episode `id`, ISO 8601 `occurredAt`, episode `kind`, display
`title`, and the source content hash in `sha256`.

Direct file ingestion produces `md`, `pdf`, `voice`, `image` and `video`.
Notion pages use `md` because live sync renders and ingests them as Markdown.
Other workflows can add kinds such as `standup` and `inquiry`, and a restored
bundle preserves the episode kind it exported.

Examples:

```
$ ed companion episodes --limit 3
#  TITLE           KIND  OCCURRED
1  Planning notes  md    2026-08-09T06:30:00.000Z
2  Edith launch    md    2026-08-08T18:10:00.000Z

$ ed companion episodes --limit 50 --json
[
  {
    "id": "5d4c0ebf-1086-46fb-ab93-dd325ed197f3",
    "kind": "md",
    "occurredAt": "2026-08-09T06:30:00.000Z",
    "sha256": "a46b0c249b09d97a9a2eeb66e995fe56d6513fbb80a4f711f846d6b92e98a1e3",
    "title": "Planning notes"
  }
]
```

Behaviour: this is a read-only `GET /v1/episodes`. `--limit` must be greater
than zero. The backend returns at most 200 items, and an empty backend returns
an empty JSON array or a table header with no rows.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
