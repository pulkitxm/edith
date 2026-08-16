# `ed companion ingest`

Scans Markdown, audio recordings, PDFs, photos and videos and posts them to the
companion.

Usage:

```
ed companion ingest <path> [--json] [--endpoint <url>]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<path>` | supported file or directory | required | Reads one file or recursively finds supported files below a folder. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | resolution order | Uses this Companion API base URL. |

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

Supported extensions are:

| Kind | Extensions | Limit | Episode body |
| --- | --- | --- | --- |
| Markdown | `.md` | 2 MB | Original text, including front matter. |
| Audio | `.wav`, `.m4a`, `.mp3`, `.ogg`, `.flac`, `.aiff` | 48 MB | whisper.cpp transcript, with language, duration and timed segments in metadata. |
| PDF | `.pdf` | 48 MB | Extracted text. Image-only PDFs are rejected because there is no OCR path. |
| Photo | `.jpg`, `.jpeg`, `.png`, `.heic`, `.heif`, `.webp`, `.gif` | 48 MB | Vision caption plus available EXIF capture details. |
| Video | `.mp4`, `.mov`, `.m4v`, `.mkv`, `.webm`, `.avi` | 768 MB | Speech transcript plus captions from scene-change keyframes. |

Behaviour: a directory walk is recursive, skips hidden files, and sorts each
kind by relative name before upload. The file modification time is sent as a
fallback event time. Oversized files are skipped before any request and named
on stderr. No supported file is a usage error. Markdown is posted in batches
of at most 200; every binary file is uploaded individually.

Audio waits for speech-to-text. Photos wait for the configured vision model.
Video requires `ffmpeg` and `ffprobe`, extracts mono audio when possible,
transcribes it, detects scene changes, spaces retained keyframes by at least 10
seconds, caps them at 200, and captions them with the vision model. A video can
still be stored when no speech is found. `exiftool` is optional for capture
metadata. All original bytes stay in the vault and all new episodes are queued
for background indexing.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
