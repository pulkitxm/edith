# `ed companion ingest`

Scans Markdown, audio recordings and PDFs and posts them to the companion.

Usage:

```
ed companion ingest <path> [--json] [--endpoint <url>]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<path>` | `.md`, audio or `.pdf` file, or a directory | required | Reads one file or recursively finds Markdown, audio (`.wav`, `.m4a`, `.mp3`, `.ogg`, `.flac`, `.aiff`) and PDFs below a folder. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | environment or local default | Uses this Companion API base URL. |

`--json` shape:

```json
{
  "duplicates": 1,
  "ingested": 1,
  "results": [
    {
      "episodeId": "5d4c0ebf-1086-46fb-ab93-dd325ed197f3",
      "name": "daily/2026-08-09.md",
      "occurredAt": "2026-08-09T06:30:00.000Z",
      "status": "ingested"
    },
    {
      "episodeId": "b938dfb5-cc52-477c-8be2-3997c59931aa",
      "name": "projects/edith.md",
      "occurredAt": "2026-08-08T18:10:00.000Z",
      "status": "duplicate"
    }
  ],
  "skipped": 1
}
```

`ingested`, `duplicates` and `skipped` are counts for the whole scan. Every
posted file has one item in `results`: `name` is the filename or its path
relative to the scanned folder, `status` is `ingested` or `duplicate`,
`episodeId` identifies the stored episode, and `occurredAt` is its ISO 8601
event time. Oversized files are counted in `skipped` but have no result item.

Examples:

```
$ ed companion ingest ./notes
ingested  daily/2026-08-09.md
duplicate  projects/edith.md
1 ingested, 1 duplicates, 0 skipped

$ ed companion ingest ./notes --json
{
  "duplicates": 0,
  "ingested": 0,
  "results": [],
  "skipped": 0
}
```

Behaviour: a directory walk is recursive, skips hidden files, and sorts names
before upload. The file modification time is sent as a fallback event time.
Markdown larger than 2MB and audio larger than 48MB are skipped with a note on
stderr. No matching file is a usage error. Markdown is posted in batches of at
most 200; audio uploads one file at a time and waits while the companion
transcribes it with whisper.cpp, so a long recording takes a while. The
transcript becomes the episode body with kind `voice`, the detected language,
the duration, and per-segment timings kept in the episode metadata. PDFs upload
one at a time and land as kind `pdf` with their extracted text as the body;
scanned PDFs without a text layer are rejected with a clear error.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
