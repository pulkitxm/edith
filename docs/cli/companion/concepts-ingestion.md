# Ingestion: from a dropped file to an episode

Part of [how the companion works](./concepts.md), under
[`ed companion`](./README.md) in [the CLI reference](../README.md). This page
follows a file through the front door: how it is fingerprinted, deduplicated,
preserved, read, dated and titled, for each of the five media the companion
accepts.

## The ways in

Everything enters through five HTTP routes, and every client funnels into
them:

| Route | Accepts | Used by |
| --- | --- | --- |
| `POST /v1/ingest` | Markdown text, up to 200 files per call | `ed companion ingest`, drops on the app, the Capture screen's typed notes |
| `POST /v1/ingest/pdf` | One PDF as base64 bytes | drops and `ed companion ingest` on `.pdf` files |
| `POST /v1/ingest/audio` | One recording as base64 bytes | drops, `ed companion ingest` on audio, the Capture screen's voice notes |
| `POST /v1/ingest/image` | One photo as base64 bytes | drops and `ed companion ingest` on supported images |
| `POST /v1/ingest/video` | One video as base64 bytes | drops and `ed companion ingest` on supported videos |

The CLI rejects Markdown over 2 MB, audio, PDF and image files over 48 MB, and
video over 768 MB before a request. Its folder scan walks recursively, skips
hidden files, keeps names relative to the selected folder, batches Markdown
200 at a time, and sends every binary file one by one.

## Step one, always: the fingerprint

The first thing the server does with any file is compute its SHA-256 hash
(a content fingerprint, see [memory](./concepts-memory.md) for the one
paragraph version). For Markdown the hash covers the text; for every binary
format it covers the raw bytes.

The `sources` table has a uniqueness rule on that fingerprint, so the check
is one lookup: if a source with this hash already exists, the answer is
`duplicate` and the request stops there. Nothing is written, no episode is
created, and re-dropping your whole notes folder is therefore harmless and
cheap. This also defines identity: the companion does not care about
filenames or paths, only content. The same note under two names is one
memory; the same name with edited content is two.

Each new file gets its own database transaction for the `sources` and
`episodes` rows, so a database failure cannot commit half a memory. The vault
is a filesystem rather than part of that transaction. Its content-addressed,
create-once path makes retries safe, though a database failure after the file
write can leave an unreferenced vault object.

## Step two: preserve the original

Before any parsing, the exact bytes go into the vault at a path derived from
the fingerprint (`/vault/objects/<xx>/<sha256>/<name>`). Parsing and
transcription are lossy; the vault write means the ground truth is safe
before anything lossy happens, and it is what the app or CLI later downloads
for opening and playback.

## Step three: turn the file into an episode

From here the five media diverge.

### Markdown

The text is stored as the episode body **whole**, front matter included, so
nothing you wrote is thrown away. Two things are parsed out of it:

**Front matter** is an optional block at the very top of a note, fenced by
`---` lines, holding `key: value` pairs:

```
---
title: Goa trip debrief
date: 2026-08-03
---
Long unstructured mornings before any screen time...
```

The companion reads it with a deliberately small scanner, not a full YAML
parser: one `key: value` per line, optional single or double quotes around
the value, everything else ignored.

**The title** is resolved in order: the front matter `title`, else the first
`# ` heading in the body, else the filename without its extension.

**The date** becomes the episode's `occurred_at`, the moment this memory
belongs to in your life. Resolution order:

1. A front matter date, read from the first of `date`, `created` or
   `occurred_at` that appears. Accepted formats: a plain `YYYY-MM-DD`
   (interpreted as midnight UTC) or a full RFC 3339 timestamp.
2. Otherwise the file's modification time, if the client sent it.
3. Otherwise the moment of ingestion.

This ordering is why importing an old journal keeps entries at their written
dates instead of piling everything onto import day. One sharp edge: the
scanner commits to the **first** matching key even if its value fails to
parse. `date: someday` followed by a valid `created: 2026-08-03` yields no
front matter date at all, and the mtime fallback takes over.

### PDF

The server extracts the text layer from the PDF and stores that as the
episode body. A PDF that yields no text, which in practice means a scanned
document that is only images, is rejected with a clear error: there is no
OCR yet, and silently storing an empty body would create a memory that can
never be found. Page structure is not preserved; the body is the flowed text.

### Voice

Audio goes to whisper.cpp, an open-source speech-to-text engine running as
its own container. Speech-to-text is a machine-learning model that converts a
waveform into text; whisper also reports which language was spoken, the total
duration, and a list of **segments**, each a phrase with start and end
timestamps. The companion calls it with temperature 0, which means "always
pick the most likely word, never sample creatively", so the same recording
always transcribes the same way.

From the result:

- The transcript text becomes the episode body, so voice memos are searchable
  exactly like typed notes.
- The detected language and the duration are stored on the episode.
- The segments, with their timings, are kept in the episode's `meta` JSON.
- `media_ref` records the vault fingerprint, marking that a playable original
  exists.

An empty transcription is treated as an error rather than stored, same logic
as the scanned PDF: a memory with no findable text is worse than a clean
failure. Transcription failures surface as HTTP 502, "the helper service
failed", distinct from 422, "your file is unusable".

### Photos

JPEG, PNG, HEIC, HEIF, WebP and GIF files go to the configured vision model.
The episode body is the model's caption followed by a plain-text line of
capture details. When `exiftool` is installed, those details can include the
original capture time, GPS coordinates and camera model; the parent folder is
also kept as an album hint. EXIF capture time wins over file mtime for
`occurred_at`. The original image remains in the vault and `media_ref` marks
it as retrievable.

A missing or unresponsive vision model makes image ingestion fail rather than
inventing an empty caption. `ed companion doctor` checks that the configured
vision model is actually pulled, not merely that the endpoint answers.

### Video

MP4, MOV, M4V, MKV, WebM and AVI files use `ffmpeg` and `ffprobe`. The backend
extracts mono 16 kHz audio and transcribes it when speech exists. Separately,
it detects scene changes, keeps frames at least 10 seconds apart up to a cap of
200, and asks the vision model to caption those frames. The episode body joins
the transcript with timestamped visual captions. A silent video explicitly
says that no speech could be transcribed, rather than failing.

The video duration, speech segments and keyframe captions live in episode
metadata. The same delivery signals used for voice are computed when segments
exist. Video is the heaviest ingest path and can run for up to 15 minutes from
the CLI before timing out.

## Step four, spoken media: signals

Right after a voice or video episode commits, the companion computes **signals**,
simple numeric observations about the delivery of your speech, straight from
the segment timings, no ML involved:

| Signal | How it is computed | Guard |
| --- | --- | --- |
| `pause_s` | The silent gap between two consecutive segments | Only gaps of 1 second or more |
| `wpm` | Words divided by minutes, per segment | Only segments of 2 seconds or more with at least 3 words |
| `speech_ratio` | Spoken time divided by total time, one value per recording | Clamped between 0 and 1 |

The guards exist to avoid noise: a 0.3 second breath is not a pause worth
recording, and a two-word segment gives a meaningless speaking rate. Signals
are the "how you sounded" channel next to the transcript's "what you said";
the Library renders them as the delivery bars under a voice episode. They are
stored per episode and are not searched or fed to the reasoner today.

## Step five: hand off to indexing

Ingestion deliberately stops at the episode. Chunking and embedding (the
expensive part, covered in
[chunks, embeddings and search](./concepts-search.md)) run separately, and
ingest simply nudges that machinery: when at least one file in a request was
genuinely new, the server spawns indexing in the background. Your drop
returns as soon as rows are committed; a few seconds later the episode has
chunks and becomes findable. The `pendingEpisodes` count in
`ed companion status`, and the amber tile in the Library, are exactly the
episodes sitting in the gap between these two steps, and `ed companion index`
closes the gap by hand.

## What can go wrong, and how it reads

| Outcome | Meaning |
| --- | --- |
| `ingested` | New memory, episode created, indexing nudged |
| `duplicate` | Content already known, nothing written |
| HTTP 422 | The file itself is unusable: empty text, scanned PDF |
| HTTP 502 | A helper failed: speech-to-text, vision, `ffmpeg`, or another media dependency |
| Exit 4 from `ed` | The backend itself is unreachable |

## Reading on

- [Memory](./concepts-memory.md): the ladder these episodes sit in, and the
  append-only rules.
- [Chunks, embeddings and search](./concepts-search.md): what happens in the
  background step right after ingestion.
