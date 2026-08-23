# `ed download reveal`

Selects every file produced by one completed download in Finder.

Usage:

```
ed download reveal <n> [--json]
```

`<n>` is the one-based position from `ed download ls`. The record must be
`done`, and each recorded result must still exist in the music folder. Missing
history exits 3 or 4 with an actionable diagnostic. Missing files exit 3 and
print the expected path as the hint.

Plain output prints one revealed absolute path per line. JSON output contains
the action, index and paths:

```json
{
  "action": "reveal",
  "files": ["/Users/me/Music/Night Drive.m4a"],
  "id": "58F41E66-1D3E-4C0C-9D89-63DC3C082D79",
  "index": 1
}
```

This is interactive and non-destructive. It uses the same completed result
resolution as the Download sheet and `ed download open`.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [`ed download open`](./open.md), open the same files
- [All `ed` commands](../README.md)
