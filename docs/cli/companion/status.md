# `ed companion status`

Reports how much the companion currently stores and when an episode was most
recently ingested.

Usage:

```
ed companion status [--json] [--endpoint <url>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | resolution order | Uses this Companion API base URL. |

`--json` shape:

```json
{
  "chunks": 126,
  "claims": 18,
  "episodes": 42,
  "latestIngestedAt": "2026-08-09T08:14:22.301Z",
  "observations": 64,
  "pendingEpisodes": 2,
  "sources": 39
}
```

`sources` counts unique ingested contents across notes and binary media,
`episodes` counts appended memory events,
and `claims` and `observations` count derived records. `chunks` counts embedded
search chunks, and `pendingEpisodes` counts episodes that have no chunks yet.
`latestIngestedAt` is the most recent ingest time as an ISO 8601 string, or
`null` when no episode exists.

Examples:

```
$ ed companion status
RESOURCE          COUNT
sources           39
episodes          42
claims            18
observations      64
chunks            126
pending episodes  2
latest  2026-08-09T08:14:22.301Z

$ ed companion status --endpoint http://127.0.0.1:4821 --json
{
  "chunks": 126,
  "claims": 18,
  "episodes": 42,
  "latestIngestedAt": "2026-08-09T08:14:22.301Z",
  "observations": 64,
  "pendingEpisodes": 2,
  "sources": 39
}
```

Behaviour: this is a read-only `GET /v1/status`. A bare `ed companion` runs the
same command. If no API answers at the resolved endpoint, stdout stays empty,
the diagnostic names that endpoint on stderr, and the command exits 4.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
