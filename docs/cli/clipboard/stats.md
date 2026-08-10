# `ed clipboard stats`

Reports how much the history is holding.

```
ed clipboard stats [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "byKind": [
    {
      "count": 517,
      "kind": "text",
      "sizeBytes": 345088
    },
    {
      "count": 40,
      "kind": "richText",
      "sizeBytes": 28672
    },
    {
      "count": 229,
      "kind": "html",
      "sizeBytes": 2516582
    },
    {
      "count": 35,
      "kind": "image",
      "sizeBytes": 43230003
    },
    {
      "count": 87,
      "kind": "file",
      "sizeBytes": 73728
    },
    {
      "count": 309,
      "kind": "data",
      "sizeBytes": 39936
    }
  ],
  "count": 1217,
  "diskBytes": 46714880,
  "largestBytes": 9227145,
  "newest": "2026-08-06T23:02:21Z",
  "oldest": "2026-07-27T09:43:29Z",
  "pinned": 3,
  "sizeBytes": 46234009
}
```

The `kind` inside `byKind` is the family, not the extension, which is the
opposite of what `kind` means in an entry object. Families with no entries are
left out entirely rather than reported as zero, and the array stays in the fixed
family order `text`, `richText`, `html`, `image`, `file`, `document`, `media`,
`data` rather than being sorted.

`sizeBytes` totals what the entries claim; `diskBytes` is what the blob
directory actually occupies. They differ when two entries share one blob,
because a blob is keyed by its hash and stored once, and when a blob is
orphaned. `oldest` is the earliest capture time, `newest` the most recent copy
time, so a `copy` of an old entry moves `newest` without moving `oldest`.

Examples:

```
ed clipboard stats
ed clipboard size
ed clipboard stats --json
```

```
$ ed clipboard stats
ITEMS  PINNED  SIZE     ON DISK  LARGEST  OLDEST
1217   3       46.2 MB  46.7 MB  9.2 MB   2026-07-27T09:43:29Z

KIND      COUNT  SIZE
text      517    345 KB
richText  40     29 KB
html      229    2.5 MB
image     35     43.2 MB
file      87     74 KB
data      309    40 KB
```

The table has no column for `newest`; take it from `--json`. With an empty
history the human path prints `the clipboard history is empty` on stderr, writes
nothing to stdout and exits 0, while `--json` still prints a full document with
`count` 0, `byKind` `[]` and both dates `null`.

## Where to go next

- [`ed clipboard`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
