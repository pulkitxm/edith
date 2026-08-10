# `ed shelf path`

Prints the full path of one shelf item.

Usage:

```
ed shelf path <n> [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<n>` | integer, 1 or more | required | The item number from `ed shelf ls`, counting from 1. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

`--json` shape, the same object `ls` emits for that item:

```json
{
  "addedAt": "2026-08-03T15:54:20Z",
  "exists": true,
  "id": "DFB41F1C-26A1-4E03-86F7-83AACFFABC28",
  "index": 1,
  "name": "screenshot.png",
  "path": "/Users/pulkit/Library/Application Support/Edith/Shelf/screenshot.png",
  "sizeBytes": 225070
}
```

Examples:

```
ed shelf path 1
ed shelf path 1 --json
open "$(ed shelf path 1)"
cp "$(ed shelf path 2)" ~/Desktop/
```

Without `--json` the output is the bare path on one line and nothing else,
which is what makes it worth substituting into another command:

```
$ ed shelf path 1
/Users/pulkit/Library/Application Support/Edith/Shelf/screenshot.png
```

Behaviour: `path` prints where the copy lives, not where the original came
from; the shelf does not record the source. It reports the path whether or not
the file is still there, so check `exists` in the JSON if that matters. A
number below 1 or above the count exits 3 and says how many items the shelf
holds, and asking on an empty shelf exits 4:

```
$ ed shelf path 9
error: there is no shelf item 9
hint: the shelf holds 2 items, numbered from 1

$ ed shelf path 1
error: the shelf is empty
hint: drag something onto the notch, or run `ed shelf add <file>`
```

## Where to go next

- [`ed shelf`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
