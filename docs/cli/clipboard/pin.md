# `ed clipboard pin`

Keeps one entry at the top and out of the retention sweep.

```
ed clipboard pin <index> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<index>` | integer, from 1 | required | The entry number, counting from 1. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "changed": true,
  "id": "5C2F0A1E-1B4D-4E0A-9A21-7C3B4D8E6F10",
  "index": 1,
  "pinned": true
}
```

Pinning exempts an entry from the sweep that `clipboardMaxItems` and
`clipboardMaxAgeDays` drive, which is the only way to keep something the history
would otherwise drop. Pinned entries sort to the top of the list unless
`ed config set clipboardPinTo bottom` says otherwise.

Pinning something already pinned is not an error: `changed` is `false`, the file
is not rewritten, `entry 1 was already pinned` goes to stderr, and the exit code
is 0.

Examples:

```
ed clipboard pin 1
ed clipboard pin 3 --json
```

```
$ ed clipboard pin 3
pinned entry 3
```

## Where to go next

- [`ed clipboard`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
