# `ed download add`

Queues one or more YouTube URLs.

Usage:

```
ed download add <url>... [--kind audio|video] [--prefix <text>] [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<url>...` | one or more strings | required | The links to download. At least one is required. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--kind <k>` | `audio` or `video` | `audio` | What to fetch. `audio` extracts to m4a, `video` merges best video and audio into mp4. |
| `--prefix <text>` | string | `""` | Prepended to the saved filename, so `--prefix roadtrip_` saves `roadtrip_Title.m4a`. |
| `--json` | flag | off | Emits one JSON document on stdout. |

Arguments are joined with newlines and handed to the same parser the sheet's
paste box uses, which splits on commas, newlines and carriage returns, trims
each piece, and keeps only what parses as a URL whose host contains
`youtube.com` or `youtu.be`. So a comma-separated list inside one quoted
argument works, several arguments work, and anything else in the line is
dropped without comment: a Vimeo link, a bare video id, or a sentence with a
link in it all contribute nothing. If nothing survives, the command exits 1
rather than queueing an empty batch:

```
$ ed download add "check this out"
error: none of that looked like a URL
hint: pass a link, for example https://youtu.be/dQw4w9WgXcQ
```

`--kind` is matched exactly against the two raw values; anything else exits 3
and lists them. The whole batch shares one kind and one prefix, so queue two
`add` commands when you want one of each.

`--json` shape, an array with one object per URL that was queued, in the order
they were parsed:

```json
[
  {
    "detail": "",
    "index": 1,
    "kind": "audio",
    "queuedAt": "2026-08-07T19:20:31Z",
    "state": "queued",
    "title": "https://youtu.be/dQw4w9WgXcQ",
    "url": "https://youtu.be/dQw4w9WgXcQ"
  }
]
```

The `index` here counts within what was just added, not the position in the
queue. Read `ed download ls --json` if you need queue positions.

Examples:

```
ed download add https://youtu.be/dQw4w9WgXcQ
ed download add https://youtu.be/dQw4w9WgXcQ --kind video --prefix roadtrip_
ed download add "https://youtu.be/a,https://youtu.be/b" --json
```

```
$ ed download add https://youtu.be/dQw4w9WgXcQ
queued https://youtu.be/dQw4w9WgXcQ
Edith is not running, so this starts when you next open it
```

Behaviour: `add` writes the new records to the front of `downloads.json` and
posts `downloadQueueChanged`, which a running Edith takes as a cue to re-read
the file and start on the next queued item. Duplicates are not detected: adding
a URL that is already queued or already downloaded queues it again. The saved
file goes to your music folder, which is `musicFolderPath` when you have set
one, `<repoPath>/local/music` when only `repoPath` is set, and
`~/Library/Application Support/Edith/music` otherwise. The note about
Edith not running goes to stderr, only when the menu bar app is absent, and
only on the human path; `--json` never prints it, and either way the exit code
is 0 because the queue write succeeded.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
