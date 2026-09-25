# `ed attention summary`

Returns active and idle time, time per kind and category, deep work blocks,
meaningful context switches with the most common transitions, attention span,
keystroke, click and scroll counts, agent working time, resolved entities and
music listening totals.

```
ed attention summary [--range <window>] [--json]
```

`--range` accepts `today`, `yesterday`, `24h`, `7d`, `30d`, `week`, `month`,
`all`, or another positive compact window such as `12h` or `2w`. It defaults to
`today`.

A context switch counts only visits of at least ten seconds. A deep work block is
a stretch of productive time at least as long as the setting in Attention, 25
minutes by default, that tolerates interruptions of up to two minutes.

Each JSON entity has a stable `id`, display `name`, category fields, where the
category came from as `categorySource` (`user`, `catalog`, `jev` or `none`), Jev's
`confidence`, source, `durationSeconds`, `visits`, `categorySeconds` and optional
`faviconURL`. Pass its ID to
`ed attention categories set` to reclassify it. The summary immediately reflects
the new rule, including historical events.

## Where to go next

- [CLI index](../README.md)
- [`ed attention categories set`](./categories/set.md)
- [`ed attention timeline`](./timeline.md)
