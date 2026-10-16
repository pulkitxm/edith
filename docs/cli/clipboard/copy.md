# `ed clipboard copy`

Puts one entry back on the pasteboard, the same as clicking it in the panel.

```
ed clipboard copy <index> [--plain] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<index>` | integer, from 1 | required | The entry number, counting from 1. |
| `--plain` | flag | off | Copy as plain text even when the entry is styled. |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` is the entry object exactly as `ls` emits it, with no extra keys. It
reports the entry as it was before the copy, so `copiedAt` is the previous copy
time rather than this one.

The whole pasteboard is replaced: `clearContents` first, then the entry's own
type. Rich text and HTML are written twice, once in their own type and once as a
plain string, so an app that only understands text still gets something. A
copied file goes back as a file URL, and a list of files goes back as a list of
them, which is why pasting one into Finder works; a copied web link goes back as
both a URL and a string. `--plain` only bites on a text, rich text or HTML
entry; on an image or a file it is quietly ignored and the real type is written.

Two side effects come with it. The entry's `lastCopiedAt` is bumped, so it moves
to the top of the list and everything that was above it shifts down by one. And
the pasteboard is stamped with a private `com.pulkit.edith.clipboard.own` type,
which is how the app's watcher knows this came from Edith and does not file it
as a fresh entry.

Examples:

```
ed clipboard copy 1
ed clipboard copy 4 --plain
ed clipboard copy 2 --json
```

```
$ ed clipboard copy 4
copied entry 4
```

An entry whose blob has gone missing under the index exits 3 with `the stored
copy of that entry is gone`, and nothing reaches the pasteboard.

## Where to go next

- [`ed clipboard`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
