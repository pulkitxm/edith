# `ed calendar join`

Finds an event by exact ID, exact title, or an unambiguous title fragment and
opens its detected meeting URL.

```text
ed calendar join <event> [--json]
```

JSON reports `action`, `id`, `title`, `url`, and `opened`. Exit 3 means the
event was missing or ambiguous. Exit 4 means the calendar was unavailable or
the selected event had no meeting link. The resolver searches the same bounded
120-day maximum as the UI. Completion offers live event IDs when the running
app answers quickly.

- [`ed calendar`](./README.md)
- [All command groups](../README.md)
