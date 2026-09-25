# `ed attention summary`

Returns active and idle time, time per productivity level, per category and
for work versus personal, a productivity pulse from 0 to 100, deep work blocks,
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

Every category has a default productivity (`very_productive`, `productive`,
`neutral`, `distracting` or `very_distracting`) and a sphere (`work`, `personal` or
`both`). A rule can override either one for a single app, site, title or Edith
context, so a site can be Social yet productive and personal for you. The pulse
weighs very productive time 4, productive 3, neutral 2, distracting 1 and very
distracting 0, over classified time only.

Each JSON entity has a stable `id`, display `name`, category fields, its
`productivity` and `sphere`, where the
category came from as `categorySource` (`user`, `catalog`, `jev` or `none`), Jev's
`confidence`, source, `durationSeconds`, `visits`, `categorySeconds` and optional
`faviconURL`. Pass its ID to
`ed attention categories set` to reclassify it. The summary immediately reflects
the new rule, including historical events.

## Where to go next

- [CLI index](../README.md)
- [`ed attention categories set`](./categories/set.md)
- [`ed attention timeline`](./timeline.md)
