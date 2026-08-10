# `ed music rescan`

Reads the music folder again, which is what to run after adding or removing
files behind Edith's back.

```
ed music rescan [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "tracks": 128
}
```

```
ed music rescan
ed music rescan --json
```

`tracks` is the count taken after the cached library root and per-folder track
counts were dropped and the folder was walked again. It is the only field: a
fresh `ed` starts with a cold cache, so a count taken before the walk would only
ever repeat it. The human line prints the same number: `128 track(s) in the
library`.

This walks the disk itself and needs nothing running, then posts
`musicFolderChanged` so a live Edith rescans too. With no music folder
configured it exits 4.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
