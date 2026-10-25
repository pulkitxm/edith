# `ed app open`

Opens Edith's main window.

```
ed app open [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` shape:

```json
{
  "action": "open",
  "requested": true
}
```

Examples:

```
ed app open
ed app open --json
```

The running Edith app receives the request and shows its main window. Closing
the window leaves that app process alive, so this is the counterpart to
`ed app quit --yes`. The command exits 4 when the matching app is unavailable.
`ed app relaunch --yes` can start the matching installation from cold.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
