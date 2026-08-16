# `ed config get`

Prints one setting's current value and nothing else, which is what to pipe into
something.

```
ed config get <key> [--json]
```

| Argument | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `key` | a catalogue key | required | The setting to read |

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | `false` | Emit JSON on stdout |

A string setting prints raw, with no quotes. A setting with no value prints an
empty line. Anything else prints as compact JSON on one line, so a number prints
`60`, a bool prints `true` and a list prints `["/"]`.

`--json` prints the full description rather than the bare value:

```json
{
  "allowed": [],
  "default": 60,
  "group": "limits",
  "isSet": false,
  "key": "warnPercent",
  "readOnly": false,
  "scope": "shared",
  "summary": "Percentage at which a limit turns amber.",
  "type": "int",
  "value": 60
}
```

```
ed config get musicFolderPath
ed config get clipboardMaxItems
ed config get limitsProvider --json
```

An unknown key exits 3. When any catalogue key contains what you typed, the hint
lists up to five of them, case-insensitively:

```
$ ed config get limits
error: no setting named limits
hint: did you mean: claudeLimitsEnabled, codexLimitsEnabled, limitsProvider, limitsInMenuBar, backupLimits
```

## Where to go next

- [`ed config`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
