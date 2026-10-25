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
  "requested": true,
  "state": "arming"
}
```

Examples:

```
ed app clean-keys
ed app clean-keys --json
```

The command uses the System extension's keyboard-cleaning engine and reports
`arming` or `cleaning` after the engine accepts the request. Without `--json`,
it prints `keyboard cleaning is arming` or `keyboard is locked`.

The matching app and enabled System extension are required. Missing Input
Monitoring or Accessibility produces exit 4 with a permission-specific hint.
The response checks both permissions and the engine phase before reporting
that the keyboard lock has started.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
