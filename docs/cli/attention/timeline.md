# `ed attention timeline`

Lists raw stored events, newest first.

```
ed attention timeline [--range <window>] [--limit <count>] [--json]
```

The default range is `today` and the default limit is 100. Pass `--limit 0` for
every matching event. JSON rows include timestamps, exact duration, source,
presence, application, browser, page, profile, and media fields allowed by the
configured privacy level.

Use `summary` for deduplicated totals. The timeline intentionally exposes both the
native browser application heartbeat and the page heartbeat when both were
observed.

## Where to go next

- [CLI index](../README.md)
- [`ed attention summary`](./summary.md)
