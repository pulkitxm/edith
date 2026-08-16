# `ed companion search`

Searches embedded memory chunks with hybrid vector and full-text retrieval.

Usage:

```
ed companion search <query> [--limit <n>] [--json] [--endpoint <url>]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<query>` | text | required | Supplies the memory search text. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--limit` | integer from `1` to `50` | `8` | Asks for this many ranked hits. |
| `--json` | flag | off | Emits one JSON array on stdout. |
| `--endpoint` | URL | resolution order | Uses this Companion API base URL. |

`--json` shape:

```json
[
  {
    "chunkId": "ad5085e1-6c90-471f-a58d-16e028423d10",
    "episodeId": "5d4c0ebf-1086-46fb-ab93-dd325ed197f3",
    "kind": "md",
    "occurredAt": "2026-08-09T06:30:00Z",
    "ord": 0,
    "score": 0.032787,
    "snippet": "The launch plan calls for a staged rollout after the warden review.",
    "title": "Planning notes"
  }
]
```

Each hit identifies its chunk and parent episode with `chunkId` and
`episodeId`. `title` and `occurredAt` describe the source episode and `snippet`
contains up to 300 characters of matching text. `score` is the reranker score
when the optional reranker ran, otherwise the fused retrieval score.

The current API sets `kind` to `chunk` and `ord` to `0` for every result. They
are compatibility fields, not the source episode kind or stored chunk ordinal.
Use `chunkId` and `episodeId` as the stable identifiers.

Examples:

```
$ ed companion search "launch plan" --limit 3
#  SCORE     TITLE           OCCURRED
1  0.032787  Planning notes  2026-08-09T06:30:00Z
  1  The launch plan calls for a staged rollout after the warden review.

$ ed companion search "nothing like this" --json
[]
```

Behaviour: this is a read-only `GET /v1/search`. The query is URL encoded and
`--limit` must be from 1 through 50. The backend considers up to 50 vector and
50 keyword matches, plus up to 25 entity-graph matches. It combines their
ranks, salience and recency, then optionally reranks before returning the
requested count. No hits print `no matches` in human output or `[]` with
`--json`. An unreachable API exits 4. Backend retrieval failures, including an
embedding failure currently returned as HTTP 500, exit 1 and preserve the
backend's diagnostic on stderr.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
