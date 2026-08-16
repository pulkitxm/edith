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
| `--endpoint` | URL | environment or local default | Uses this Companion API base URL. |

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
`episodeId`. `ord` is the chunk position in the episode. `title`, `occurredAt`
and `kind` describe the source episode, `snippet` contains matching text, and
`score` is the fused retrieval score.

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
`--limit` must be from 1 through 50. No hits print `no matches` in human output
or `[]` with `--json`. If the embedding service returns HTTP 502, the command
names the Ollama embedding service, leaves stdout empty, and exits 4.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
