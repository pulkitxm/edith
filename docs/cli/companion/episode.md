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
| `--endpoint` | URL | resolution order | Uses this Companion API base URL. |

`--json` shape: `{id, occurredAt, ingestedAt, kind, title, body, bodyEn, langs,
durationS, mediaRef, sha256, bytes, chunks}`. `durationS` can be present for
voice and video episodes. `mediaRef` is present for binary media, including
PDF, voice, image and video. The raw stored file is served by the backend at
`GET /v1/episodes/<id>/media`.

`--body` and `--open` are mutually exclusive in effect. `--open` takes
precedence, writes the download to a temporary file with the episode title,
and asks macOS to open it. With both `--open` and `--json`, the JSON result is
`{"opened":"<temporary-path>"}` rather than the episode object.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
