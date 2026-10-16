# `ed config unset`

Removes the stored value so the setting falls back to its catalogue default.

```
ed config unset <key> [--json]
```

| Argument | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `key` | a catalogue key | required | The setting to clear |

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | `false` | Emit JSON on stdout |

The value reported back is the effective one after the removal, so it is the
catalogue default, or `null` for a setting that declares none:

```json
{
  "key": "menuBarSubColorHex",
  "value": null
}
```

```
ed config unset appearance
ed config unset menuBarSubColorHex --json
```

Clearing a setting that was never written is a no-op that still succeeds, still
prints the default and still announces the change. Read-only keys exit 1, the
same as with `set`. Unknown keys exit 3.

## Where to go next

- [`ed config`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
