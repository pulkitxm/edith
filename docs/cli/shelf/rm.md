# `ed shelf rm`

Takes one or more selected items off the shelf.

Usage:

```
ed shelf rm <n...> [--json] [--yes]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<n...>` | one or more integers | required | Item numbers from `ed shelf ls`, counting from 1. Duplicates are ignored. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--yes` | flag | off | Applies the removal. Without it, prints the exact path. |

Without `--yes`, `rm` previews every selected item and exact shelf path while
leaving the files and index bytes unchanged.

`--json` shape:

```json
{
  "action": "remove shelf items",
  "applied": true,
  "changed": true,
  "items": [
    {
      "addedAt": "2026-08-08T11:02:57Z",
      "exists": true,
      "id": "0B7A44E2-51C8-4F0A-8D33-9C6B2E5A1477",
      "index": 1,
      "name": "report.pdf",
      "path": "/Users/pulkit/Library/Application Support/Edith/Shelf/report.pdf",
      "position": null,
      "sizeBytes": 184320
    }
  ],
  "remaining": 1,
  "removed": 2,
  "targets": ["/Users/pulkit/Library/Application Support/Edith/Shelf/report.pdf"]
}
```

`removed` is the number of unique selected items. `items` contains the full
documents previewed before deletion, and `remaining` is how many items are left.

Examples:

```
ed shelf rm 1
ed shelf rm 1 3 --yes --json
```

```
$ ed shelf rm 1 3 --yes
removed 2 items, 1 left
```

Behaviour: `rm` deletes the shelf's copy outright. It does not go to the Trash,
unlike `ed music rm` and `ed cleaner clean`, and it is not recoverable, so the
copy is gone even though whatever you originally added is untouched. A copy
that is already missing is not an error: the index entry is dropped and the
command still exits 0.

Numbers shift after every removal, because they are positions in a newest-first
list rather than ids. Pass a whole selection in one invocation when the numbers
must resolve against one snapshot.

An index below 1 or above the count exits 3, and `rm` on an empty shelf exits 4
with the same message `path` gives.

## Where to go next

- [`ed shelf`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
