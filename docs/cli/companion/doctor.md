# `ed companion doctor`

Asks the backend to check each service it depends on.

Usage:

```
ed companion doctor [--json] [--endpoint <url>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | resolution order | Uses this Companion API base URL. |

`--json` shape:

```json
{
  "checks": [
    { "detail": "connected", "name": "postgres", "ok": true, "severity": "blocker" },
    { "detail": "installed", "name": "pgvector", "ok": true, "severity": "blocker" },
    { "detail": "connected", "name": "redis", "ok": true, "severity": "optional" },
    { "detail": "not configured, fusion order kept", "name": "reranker", "ok": false, "severity": "optional" }
  ],
  "degraded": true,
  "ok": true
}
```

Each item in `checks` has the dependency `name`, its own Boolean `ok`, a
human-readable `detail` from the backend, and a `severity`:

| Severity | Meaning |
| --- | --- |
| `blocker` | The companion cannot do its job without it. |
| `degraded` | One capability is lost, the rest still works. |
| `optional` | Off by choice; nothing is broken. |

`ok` is true when no `blocker` check is failing, so an unconfigured reranker
does not make the companion unhealthy while an unconfigured reasoning provider
does. `degraded` is true when any check at all is failing, including optional
ones. `/v1/health` answers 200 when `ok` and 503 otherwise.

The full check set is Postgres, migrations, pgvector, Redis, vault
writability, embeddings, speech-to-text, reasoning, reranker, grounding,
vision, Notion, GitHub, media tooling and personas. Embeddings verifies both
the Ollama version and a real model response. A successful model response is
cached for five minutes so repeated health polling does not keep loading the
model. Vision checks that the configured model appears in `/api/tags`. Media
tooling requires `ffmpeg` and `ffprobe`; `exiftool` is reported when present
but is not required. The vault check creates, writes and removes a temporary
file.

Examples:

```
$ ed companion doctor
postgres  ok  connected
migrations  ok  12 of 12 migrations applied
pgvector  ok  installed
embeddings  ok  ollama 0.32.6, model qwen3-embedding:0.6b loaded
reasoning  ok  openai-compatible at http://ollama:11434/v1, model qwen3:1.7b
reranker  off  not configured, fusion order kept
github  off  no token; set it from the app or `ed companion connectors set`

$ ed companion doctor --json
{
  "checks": [
    { "detail": "connected", "name": "postgres", "ok": true, "severity": "blocker" }
  ],
  "degraded": false,
  "ok": true
}
```

A failing `blocker` is also summarised on stderr after the human-readable table:

```
$ ed companion doctor
reasoning  FAIL  no reasoning provider; set one from the app or `ed companion reason set`
1 blocking: reasoning
```

Behaviour: `doctor` decodes the health report even when the API returns HTTP
503. A reachable but unhealthy backend still exits 0 because health lives in
the payload, where scripts can inspect `ok`. Failure to reach the API exits 4.
`--json` writes only the report to stdout. In human mode the per-check table is
stdout and the blocking summary, when present, is stderr.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
