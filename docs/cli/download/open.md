# `ed download open`

Opens every file produced by one completed download.

Usage:

```
ed download open <n> [--json]
```

`<n>` is the one-based position from `ed download ls`. The record must be
`done`, and each recorded result must still exist in the music folder. Missing
history exits 3 or 4 with an actionable diagnostic. Missing files exit 3 and
print the expected path as the hint.

Plain output prints one opened absolute path per line. JSON output contains the
action, index and paths:

```json
{
  "action": "open",
  "files": ["/Users/me/Music/Night Drive.m4a"],
  "index": 1
}
```

This is interactive and non-destructive. For automation that only needs paths,
read the `detail` field from `ed download ls --json` without opening anything.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [`ed download reveal`](./reveal.md), select the same files in Finder
- [All `ed` commands](../README.md)
