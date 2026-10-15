# `ed music shuffle`

Turns shuffle on or off for Edith's own player, or reports it.

```
ed music shuffle [state] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `state` | `on`, `off`, `true`, `false`, `yes`, `no`, `1`, `0`, `enabled`, `disabled` | none, which reports | What to set shuffle to. Leave it out to read the current value. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "shuffle": true
}
```

```
ed music shuffle
ed music shuffle on
ed music shuffle off --json
```

Reading prints `on` or `off`. Setting prints `shuffle on` or `shuffle off` and
writes the `musicShuffling` preference, which is the same key
`ed config set musicShuffling true` writes and the same footer toggle the UI
shows. The write lands whether or not Edith is running; the notification that
tells a live player to reorder its queue only matters when one is listening, so
this never exits 4.

The words are matched case-insensitively. A word that is not one of them exits
1, not 2, with `<state> is not on or off` and the hint `pass on, off, true or
false`.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
