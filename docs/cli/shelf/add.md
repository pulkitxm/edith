# `ed shelf add`

Copies a file onto the shelf.

Usage:

```
ed shelf add <file> [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<file>` | path to an existing file or directory | required | What to park. `~` is expanded, and a relative path resolves against your current directory. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

`--json` shape, the new item, always at index 1 because it is the newest:

```json
{
  "addedAt": "2026-08-08T11:02:57Z",
  "exists": true,
  "id": "0B7A44E2-51C8-4F0A-8D33-9C6B2E5A1477",
  "index": 1,
  "name": "report 2.pdf",
  "path": "/Users/pulkit/Library/Application Support/Edith/Shelf/report 2.pdf",
  "sizeBytes": 184320
}
```

Examples:

```
ed shelf add ./report.pdf
ed shelf add ~/Downloads/build.zip
ed shelf add ~/Projects/notes
ed shelf add ./report.pdf --json
```

```
$ ed shelf add ./report.pdf
shelved report.pdf

$ ed shelf add ./report.pdf
shelved report 2.pdf
```

Behaviour: `add` copies rather than moves, so the file you named is still where
it was afterwards, exactly as dragging it onto the notch does: the shelf holds
its own copy and the original is left alone. The name on the shelf is the
last path component, made unique against what is already in the shelf folder by
inserting a counter before the extension: `report.pdf`, then `report 2.pdf`,
then `report 3.pdf`, and an extension-less `Makefile` becomes `Makefile 2`. The
check is against the folder, not the index, so a file left behind by a previous
shelf still forces the rename. Nothing is ever overwritten.

A path with nothing at it exits 3 with `no file at <path>` and no hint. A copy
the filesystem refuses, whether the source is unreadable, the shelf folder is
not writable, or the disk is full, exits 1 with the system's own description as
the hint:

```
$ ed shelf add /nowhere/at/all.txt
error: no file at /nowhere/at/all.txt

$ ed shelf add ./locked.txt
error: could not put locked.txt on the shelf
hint: “locked.txt” couldn’t be copied because you don’t have permission to access “Shelf”.
```

A directory is accepted and copied whole, recursively, because the copy is a
plain `copyItem`. The `sizeBytes` reported for one is what the filesystem
records for the directory entry itself, not the total of what is inside it.

## Where to go next

- [`ed shelf`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
