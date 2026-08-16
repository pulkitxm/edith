# `ed config describe`

Explains one setting. This is what to read before writing something you are
unsure of.

```
ed config describe <key> [--json]
```

| Argument | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `key` | a catalogue key | required | The setting to explain |

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | `false` | Emit JSON on stdout |

```
$ ed config describe limitsProvider
limitsProvider
  Provider shown first in the limits UI.
  type     string
  group    limits
  scope    shared
  allowed  claude, codex
  default  claude
  value    claude
```

The `allowed` line appears only when the setting has an allowed list, and a
final `read only` line appears only for the 23 keys the app owns. `--json` emits
the same object `ls` and `get` emit, which always carries every field:

```json
{
  "allowed": [
    "claude",
    "codex"
  ],
  "default": "claude",
  "group": "limits",
  "isSet": true,
  "key": "limitsProvider",
  "readOnly": false,
  "scope": "shared",
  "summary": "Provider shown first in the limits UI.",
  "type": "string",
  "value": "claude"
}
```

```
ed config describe clipboardPopupAt
ed config describe budgetMode --json
```

`isSet` is the same test `--changed` and `export` use: there is a stored value
and it differs from any registered default. Unknown keys exit 3 with the same
near-match hint `get` gives.

## Where to go next

- [`ed config`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
