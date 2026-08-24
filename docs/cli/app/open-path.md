# `ed app open-path`

Opens or reveals one path from [`ed app paths`](./paths.md).

```
ed app open-path <app-data|icloud|data|refresh-log|music> [--json]
```

Folders open with the default macOS handler. A present refresh log is revealed
in Finder; a missing one opens its containing data folder. The iCloud and music
directories are created before opening when needed, matching the UI.

Plain output names the action and exact path. JSON has `id`, `url`, `mode`, and
`opened`. `mode` is `open` or `reveal`. A parser error exits 2. A directory
preparation or macOS open failure exits 4. The command needs no Edith process.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
