# `ed clipboard unpin`

Lets one entry age out again.

```
ed clipboard unpin <index> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<index>` | integer, from 1 | required | The entry number, counting from 1. |
| `--json` | flag | off | Emit JSON on stdout. |

Identical to `pin` in every respect but the value written, including the JSON
shape, where `pinned` is `false`. Unpinning something already unpinned reports
`entry 3 was already unpinned` on stderr and exits 0.

Unpinning does not delete anything, but it does hand the entry back to the
retention sweep, so an old entry can disappear on the app's next pass.

Examples:

```
ed clipboard unpin 3
ed clipboard unpin 1 --json
```

## Where to go next

- [`ed clipboard`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
