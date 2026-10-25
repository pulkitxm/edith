# `ed app test-notification`

Sends the same test notification the settings pane sends.

```
ed app test-notification [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` shape:

```json
{
  "action": "test-notification",
  "requested": true,
  "status": "Delivered"
}
```

Examples:

```
ed app test-notification
ed app test-notification --json
```

The app sends the notification and reports a status such as `Delivered`,
`Permission not granted`, or a System Settings or Focus diagnosis. The command
requires the matching app to be running. Notification delivery belongs to the
app and is available without downloading the Usage extension.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
