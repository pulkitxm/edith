# `ed shelf ls`

Lists everything on the shelf, newest first.

Usage:

```
ed shelf ls [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments, and there is no limit, search or filter:
`ls` always prints the whole shelf.

`--json` shape, an array with one object per item, in the same order the table
prints:

```json
[
  {
    "addedAt": "2026-08-03T15:54:20Z",
    "exists": true,
    "id": "DFB41F1C-26A1-4E03-86F7-83AACFFABC28",
    "index": 1,
    "name": "screenshot.png",
    "path": "/Users/pulkit/Library/Application Support/Edith/Shelf/screenshot.png",
    "sizeBytes": 225070
  },
  {
    "addedAt": "2026-08-01T09:12:44Z",
    "exists": true,
    "id": "6C2B0A55-9F41-4B7C-9D0E-2A1F7E3C8B10",
    "index": 2,
    "name": "notes 2.pdf",
    "path": "/Users/pulkit/Library/Application Support/Edith/Shelf/notes 2.pdf",
    "sizeBytes": 48211
  }
]
```

`index` is the number `path` and `rm` take. `id` is the item's UUID from the
index file, stable for the life of the item and accepted nowhere as an
argument. `name` is the filename on the shelf, which is not always the name of
the file you added. `path` is `name` joined onto the shelf folder, so it is
always flat and always absolute. `sizeBytes` and `exists` are measured on disk
at the moment you run the command, not stored: a file removed behind the
index's back reports `"sizeBytes": 0` and `"exists": false` rather than
disappearing from the list. `addedAt` is ISO 8601 in UTC, to the second.

Examples:

```
ed shelf ls
ed shelf --json
ed shelf ls --json
```

The table is four columns: the item number, the name on the shelf, its size,
and when it was added.

```
$ ed shelf ls
#  NAME            SIZE     ADDED
1  screenshot.png  225 KB   2026-08-03T15:54:20Z
2  notes 2.pdf     48.2 KB  2026-08-01T09:12:44Z
```

Behaviour: `ls` reads the index and stats each file, writes nothing, and needs
neither the main app nor the menu bar helper. An empty shelf is not an error:
without `--json` it writes `the shelf is empty` to stderr, leaves stdout empty
and exits 0, and with `--json` it prints `[]` and exits 0. An unreadable or
absent index decodes to an empty shelf, so a corrupted index looks exactly like
a shelf you have never used.

## Where to go next

- [`ed shelf`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
