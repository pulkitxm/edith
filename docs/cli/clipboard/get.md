# `ed clipboard get`

Prints one entry as plain text on stdout, with no trailing decoration.

```
ed clipboard get <index> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<index>` | integer, from 1 | required | The entry number, counting from 1. |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` is the same entry object `ls` emits with one extra key, `text`, holding
the same string the human path prints:

```json
{
  "copiedAt": "2026-08-06T22:38:12Z",
  "family": "text",
  "id": "9B4E77C0-3A15-4F2E-B0D9-51C8E2A7F3B4",
  "index": 3,
  "isText": true,
  "kind": "sql",
  "pinned": false,
  "preview": "select id, name from machines order by name",
  "sizeBytes": 43,
  "sourceApp": "TablePlus",
  "text": "select id, name from machines order by name"
}
```

Which entries can be printed is decided by the stored extension, not by the
family:

- `rtf`, `rtfd` and `html` are rendered down to their plain text, so you get the
  words rather than the markup.
- `txt`, `json`, `xml`, `csv`, `tsv`, `plist`, `yaml`, `sql`, `sh`, `py`, `rb`,
  `pl`, `php`, `js`, `swift`, `md`, `log`, `conf`, `ini` and `toml` are decoded
  as UTF-8, falling back to UTF-16.
- everything else, images, PDFs, archives, copied files, copied URLs and any
  extension outside that list, is refused with exit 1 and pointed at
  `ed clipboard copy` instead.

That last rule is worth knowing because `isText` in the JSON can be `true` for
an entry `get` will still refuse: a snippet copied as a source-code type Edith
has no extension mapping for is filed under the `text` family but is not on the
list above.

Examples:

```
ed clipboard get 1
ed clipboard get 3 --json
ed clipboard get 1 > note.txt
ed clipboard get 1 | pbcopy
```

```
$ ed clipboard get 2
error: entry png is not text
hint: use `ed clipboard copy` to put it back on the pasteboard instead
```

Nothing is written or reordered by `get`; it does not count as a copy, so the
entry keeps its place in the list.

## Where to go next

- [`ed clipboard`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
