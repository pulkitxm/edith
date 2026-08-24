# `ed calendar directions`

Finds an event by exact ID, exact title or an unambiguous title fragment and
opens its location in Apple Maps.

```text
ed calendar directions <event> [--json]
ed calendar route <event> [--json]
```

The resolver searches the next 120 days. Completion offers live event IDs when
the running app answers within its short completion deadline.

Plain output is one line:

```text
$ ed calendar directions event-42
opening directions to 1 Infinite Loop
```

JSON has a stable object shape:

```json
{
  "action": "directions",
  "id": "event-42",
  "location": "1 Infinite Loop",
  "opened": true,
  "title": "Studio visit",
  "url": "https://maps.apple.com/?q=1%20Infinite%20Loop&ll=37.3317,-122.0301"
}
```

Exit 3 means the event was not found or the title matched more than one event.
Exit 4 means the app or calendar is unavailable, or the event has no location.
The Maps URL includes the event coordinates when EventKit provides them and
otherwise searches the location text.

For automation, list events first and pass the stable ID:

```sh
event_id=$(ed calendar ls --days 30 --json | jq -r '.[] | select(.location) | .id' | head -n 1)
ed calendar directions "$event_id" --json
```

- [`ed calendar`](./README.md)
- [`ed calendar ls`](./ls.md)
- [All command groups](../README.md)
