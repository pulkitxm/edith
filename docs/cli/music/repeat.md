# `ed music repeat`

Turns repeat on or off for Edith's own player, or reports it. Aliased `loop`.

```
ed music repeat [state] [--json]
ed music loop [state] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `state` | `on`, `off`, `true`, `false`, `yes`, `no`, `1`, `0`, `enabled`, `disabled` | none, which reports | What to set repeat to. Leave it out to read the current value. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "repeat": false
}
```

```
ed music repeat
ed music loop on
ed music repeat off --json
```

Identical to `shuffle` in every way except the preference it writes,
`musicLooping`, the command it posts to a live player, `loop`, and the JSON key,
which is `repeat` rather than the internal name. Note the mismatch that follows
from that: the verb and the JSON key are `repeat`, the setting is
`musicLooping`, and the alias is `loop`.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
