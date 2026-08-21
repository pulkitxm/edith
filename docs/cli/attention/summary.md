# `ed attention summary`

Returns active, idle, focused, communication, and entertainment time, context
switches, resolved entities, and music listening totals.

```
ed attention summary [--range <window>] [--json]
```

`--range` accepts `today`, `yesterday`, `24h`, `7d`, `30d`, `week`, `month`,
`all`, or another positive compact window such as `12h` or `2w`. It defaults to
`today`.

Each JSON entity has a stable `id`, display `name`, category fields, source,
`durationSeconds`, and optional `faviconURL`. Pass its ID to
`ed attention categories set` to reclassify it. The summary immediately reflects
the new rule, including historical events.

## Where to go next

- [CLI index](../README.md)
- [`ed attention categories set`](./categories/set.md)
- [`ed attention timeline`](./timeline.md)
