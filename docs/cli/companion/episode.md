# `ed companion episode`

Reads one episode in full: the metadata the list view shows, plus the whole
body text.

Usage:

```
ed companion episode <id> [--body] [--open] [--json] [--endpoint <url>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--body` | flag | off | Prints only the body text, for piping. |
| `--open` | flag | off | Downloads the original file from the vault and opens it with the default app. |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | environment or local default | Uses this Companion API base URL. |

`--json` shape: `{id, occurredAt, ingestedAt, kind, title, body, bodyEn, langs,
durationS, mediaRef, sha256, bytes, chunks}`. `durationS` and `mediaRef` are
`null` for anything but voice episodes. The raw stored file is served by the
backend at `GET /v1/episodes/<id>/media`.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
