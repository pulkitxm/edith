# `ed clipboard ls`

Lists the history with the number every other verb takes.

```
ed clipboard ls [--pinned] [--search <text>] [--limit <n>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--pinned` | flag | off | Keep only pinned entries. |
| `--search <text>` | string | unset | Keep only entries whose preview or source app contains this text, case-insensitively. |
| `--limit <n>` | integer, 0 or more | `25` | Show at most this many entries. Pass 0 for all of them. |
| `--json` | flag | off | Emit JSON on stdout. |

The filters run in that order: `--search` first, then `--pinned`, then `--limit`
on what is left. `--search` is trimmed and lowercased before it is used, so a
value that is only whitespace filters nothing, and it matches the preview text
and the source application, which is the same match the panel's search field
makes.

Numbers are assigned before any filtering, against the whole history, so a
number you read out of `ed clipboard ls --pinned` still names the same entry to
`get` and `rm`. The list can therefore be numbered 1, 4, 9 with no gap being an
error.

`--json` is an array of entry objects, one per shown row, in display order:

```json
[
  {
    "copiedAt": "2026-08-06T23:02:21Z",
    "family": "text",
    "id": "5C2F0A1E-1B4D-4E0A-9A21-7C3B4D8E6F10",
    "index": 1,
    "isText": true,
    "kind": "txt",
    "pinned": true,
    "preview": "ssh pulkit@10.0.0.4",
    "sizeBytes": 19,
    "sourceApp": "Ghostty"
  },
  {
    "copiedAt": "2026-08-06T22:41:08Z",
    "family": "image",
    "id": "0D1A7B33-9F42-4C58-8E71-2B6A0C4F91DD",
    "index": 2,
    "isText": false,
    "kind": "png",
    "pinned": false,
    "preview": "PNG image",
    "sizeBytes": 1245184,
    "sourceApp": "Preview"
  }
]
```

`kind` is the entry's file extension, the thing the blob is stored as: `txt`,
`json`, `sql`, `png`, `rtf`, `html`, `url`, `files`, `weburl`, `data` and so on.
`family` is the coarse bucket the app groups by, one of `text`, `richText`,
`html`, `image`, `file`, `document`, `media` or `data`. Both keys are present on
every entry object the group emits. `preview` and `sourceApp` are `null` rather
than absent when the entry has neither.

Examples:

```
ed clipboard ls
ed clipboard ls --limit 0
ed clipboard ls --pinned --json
ed clipboard ls --search token --limit 5
```

```
$ ed clipboard ls --limit 4
#  KIND          SIZE       FROM     PREVIEW
1  txt   pinned  19 bytes   Ghostty  ssh pulkit@10.0.0.4
2  png           1.2 MB     Preview  PNG image
3  html          8 KB       Safari   Edith keeps a history of everything you copy
4  txt           142 bytes  Xcode    func render(headers: [String]) -> String
```

The third column has no header; it holds the word `pinned` and is otherwise
blank. Sizes are formatted the way Finder formats them, so read `sizeBytes` from
`--json` when you need the exact count. Previews are capped at 500 characters at
capture time, and the table flattens newlines and tabs to spaces so one entry is
always one row.

A truncated list says so on stderr and still exits 0:

```
$ ed clipboard ls
showing 25 of 1217; pass --limit 0 for all of them
```

That note is only printed on the human path. `--json` never prints it, so a
script that wants everything has to pass `--limit 0` itself.

An empty history is not an error here: `ls` prints the header row and nothing
else, `ls --json` prints `[]`, and both exit 0. The verbs that take a number are
the ones that refuse.

## Where to go next

- [`ed clipboard`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
