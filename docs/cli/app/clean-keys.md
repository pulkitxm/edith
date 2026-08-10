# `ed app clean-keys`

Locks the keyboard so you can wipe it without typing into whatever is in front.

```
ed app clean-keys [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` shape:

```json
{
  "action": "clean-keys",
  "requested": true
}
```

Examples:

```
ed app clean-keys
ed app clean-keys --json
```

Without `--json` it prints `clean-keys requested`. This is the menu bar's
keyboard-cleaning lock, so it needs the helper and exits 4 with `clean-keys
needs the Edith menu bar app to be running` when the helper is closed. The
request is fire and forget: `ed` posts the notification and returns, so exit 0
means the request was sent, not that the lock came up.

What the helper does with it is the same path the System page's button takes. It
re-reads its permissions, ignores the request outright when a clean is already
under way, and if Input Monitoring or Accessibility is missing it raises that
request instead of locking; otherwise it dismisses the panel, arms the countdown
and shows the overlays. If the System extension is off the helper has no system
store at all and the notification lands nowhere, and `ed` still exits 0, so
check `ed extensions ls` for `system` when nothing happens.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
