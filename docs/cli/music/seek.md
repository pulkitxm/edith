# `ed music seek`

Jumps to a point in the current track, as a fraction of its length.

```
ed music seek <position> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `position` | number from 0 to 1 | required | Where to jump to, as a fraction of the track. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "position": 0.5
}
```

```
ed music seek 0
ed music seek 0.5
ed music seek 0.9 --json
```

The human line truncates to a whole percentage: `seeked to 50%`, and `0.999`
prints as `99%`. A position outside 0 to 1 exits 2 with `position must be
between 0 and 1`, and that check runs before the app check, so a bad number
fails the same way whether or not Edith is running.

This is the seek bar in the Music footer and it only drives Edith's own player.
There is no `--player`, and no way to seek Spotify or Apple Music from here.
With the menu bar app closed it exits 4.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
