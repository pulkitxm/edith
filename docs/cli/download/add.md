# `ed download add`

Queue one or more complete HTTP or HTTPS links. The background agent owns the
queue and runs the downloads.

```text
ed download add <url>... [--kind post|images|audio|video] [--prefix <text>]
  [--directory <path>] [--browser <name>] [--json]
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--kind` | `audio` | `post` saves a whole post, `images` saves photos, `video` saves video, `audio` extracts M4A. |
| `--prefix` | empty | Prefix for saved video and audio filenames. |
| `--directory` | depends on kind | Music for audio, `~/Downloads/Edith` for other formats. |
| `--browser` | none | Read local login cookies from `safari`, `chrome`, `firefox`, `brave` or `edge`. |
| `--json` | off | Emit an array of queued records. |

The parser accepts comma-separated or newline-separated links and removes
duplicates within a batch. Non-web URLs and URLs containing credentials are
rejected. Invalid segments are omitted; if none remain, the command fails.
Use separate requests for different formats or destinations.

```sh
ed download add 'https://www.instagram.com/p/example/' --kind post
ed download add 'https://example.com/photo.png' --kind images --directory ~/Pictures/Saved
ed download add 'https://www.youtube.com/watch?v=example' --kind video --prefix trip_
ed download add 'https://x.com/example/status/123' --kind post --browser firefox --json
```

The JSON result contains `id`, `index`, `url`, `title`, `kind`, `state`, `detail`
and `queuedAt` for each added record. `index` is its current position in the
newest-first queue; `id` remains stable when the queue changes. An accepted
request means the job was queued, not that its media has already downloaded.

Retries preserve the destination and browser choice recorded when the item was
queued. gallery-dl is required for `post` and `images`. `post` falls back to
yt-dlp when gallery-dl finds no files. Partial galleries remain failed so they
can be retried without silently presenting an incomplete post as complete.

- [`ed download`](./README.md)
- [All `ed` commands](../README.md)
