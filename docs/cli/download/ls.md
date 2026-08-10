# `ed download ls`

Lists what is in the queue, newest first.

Usage:

```
ed download ls [--active] [--limit <n>] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--active` | flag | off | Keeps only entries that have not finished: `queued`, `resolving` and `downloading`. |
| `--limit <n>` | integer, 0 or more | `25` | Shows at most this many. `0` shows all of them. |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments.

Entries are numbered from 1 in the order they are printed, which is by the time
they were queued, newest first. That number is what `ed download rm` and
`ed download retry` take, and it is recomputed on every invocation: removing
entry 1 renumbers everything below it, so read the list again between two
edits rather than counting down from an old listing.

That number counts through the whole queue, so take it from a bare `ls` or from
`ls --limit <n>`, which shows a prefix of the same list. Never take it from
`ls --active`: that numbers only what it prints, so its entry 1 is the first
unfinished download, while `rm 1` and `retry 1` mean the first entry in the
queue whatever state it is in.

`--active` filters on "not finished", and an interrupted download counts as
finished, so a paused or cancelled entry does not appear even though its file
was never written. Use a bare `ls` to see those.

`--limit` is checked before the file is read, so a negative value exits 2 and
nothing is printed.

`--json` shape, an array with one object per entry:

```json
[
  {
    "detail": "Night Drive.m4a",
    "index": 1,
    "kind": "audio",
    "queuedAt": "2026-08-07T19:12:44Z",
    "state": "done",
    "title": "Night Drive",
    "url": "https://youtu.be/dQw4w9WgXcQ"
  },
  {
    "detail": "63.4%",
    "index": 2,
    "kind": "video",
    "queuedAt": "2026-08-07T19:11:02Z",
    "state": "downloading",
    "title": "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
    "url": "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
  },
  {
    "detail": "ERROR: [youtube] Video unavailable",
    "index": 3,
    "kind": "audio",
    "queuedAt": "2026-08-07T18:55:10Z",
    "state": "failed",
    "title": "https://youtu.be/aaaaaaaaaaa",
    "url": "https://youtu.be/aaaaaaaaaaa"
  }
]
```

`state` is one of `queued`, `resolving`, `downloading`, `done`, `failed` and
`interrupted`. `detail` depends on the state: the progress yt-dlp last reported
for `downloading` (`63.4%`, or `63.4% (2/5)` while working through a playlist),
the produced filenames for `done`, the whole error text for `failed`, the
reason for `interrupted`, and an empty string for `queued` and `resolving`.
`title` is the produced file's name without its extension once the download is
`done`, and the URL itself until then. `kind` is `audio` or `video`, and an
entry written by an older Edith that recorded no kind reads back as `audio`.
`queuedAt` is ISO 8601 in UTC. The output filename template the entry was
queued with is not exposed.

Examples:

```
ed download ls
ed download ls --active
ed download ls --limit 0 --json
```

```
$ ed download ls
#  STATE        KIND   WHAT
1  done         audio  Night Drive
2  downloading  video  https://www.youtube.com/watch?v=aqz-KE-bpKQ
3  queued       audio  https://youtu.be/dQw4w9WgXcQ
```

Behaviour: `ls` reads one file and writes nothing, needs neither the main
window nor the menu bar app, and never fails because Edith is closed. An empty
queue writes `the download queue is empty` to stderr, or `nothing is
downloading` with `--active`, leaves stdout empty and exits 0. A list cut short
by `--limit` says so on stderr: `showing 25 of 41; pass --limit 0 for all of
them`. Neither note is printed under `--json`, where an empty queue is an empty
array and a truncated list is silent, so a caller never has to parse prose.
The table has four columns and `detail` is not one of them: `WHAT` is the
title, so the error text of a `failed` entry is reachable only through `--json`.
In the cells it does print, newlines, carriage returns and tabs become spaces
and every other control character is dropped, so nothing in a title can break
the columns.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
