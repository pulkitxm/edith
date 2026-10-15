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
  "requested": true
}
```

Examples:

```
ed app test-notification
ed app test-notification --json
```

Without `--json` it prints `test-notification requested`. It needs the menu bar
helper and exits 4 otherwise. The notification is sent by the Agent Usage
notifier, so it needs the `usage` extension on as well as the helper running;
with that extension off, nothing is sent and `ed` still exits 0. The helper
discards the notifier's own answer, so a notification blocked in System Settings
is silent here too: `ed permissions request notifications` is the fix.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
