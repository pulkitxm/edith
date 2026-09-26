# `ed herdr hooks`

Messages waiting for an agent to finish, from `ed herdr send --when-finished`
or the Herdr page, plus the result of the ones that already went out. The
background agent owns them, so they keep working while the Edith window is
closed.

```
ed herdr hooks [ls] [--json]
ed herdr hooks rm <id> [--json]
```

`ed herdr hooks` runs `ed herdr hooks ls`. `list` is an alias for `ls` and
`remove` for `rm`.

## `rm` arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<id>` | a hook id, or a unique prefix of it | required | Cancel a waiting message, or forget a finished one |
| `--json` | flag | off | Emit JSON on stdout |

## `--json` shape

`ls` prints `{"hooks": [...]}`.

```json
{
  "hooks": [
    {
      "agent": "local|default|w1:p2",
      "detail": null,
      "id": "1F0C2A9B-3C1D-4E2F-8A7B-6C5D4E3F2A1B",
      "machine": "local",
      "message": "Now run the full test suite.",
      "pane": "w1:p2",
      "session": "default",
      "state": "armed",
      "title": "Refactor the parser"
    }
  ]
}
```

`state` is `armed` while it waits, `sending` for the moment it goes out, then
`sent`, `skipped` (Herdr refused it, see `detail`) or `cancelled` (the agent
closed or was replaced). Finished entries are kept for a day.

`rm` prints `{"removed": "<id>"}`. An id that matches nothing, or more than one
hook, exits 3. Both commands exit 4 when the background agent is not running.

## Where to go next

- [`ed herdr send`](./send.md), send now or when an agent finishes
- [`ed herdr`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
