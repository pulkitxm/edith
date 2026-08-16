# `ed config set`

Validates a value against the setting's type and allowed list, writes it, and
tells the running app.

```
ed config set <key> <value> [--json]
```

| Argument | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `key` | a catalogue key | required | The setting to write |
| `value` | text, parsed by the setting's type | required | The new value |

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | `false` | Emit JSON on stdout |

How the text is parsed depends on the type:

| Type | Accepted text | Refused |
| --- | --- | --- |
| `bool` | `true`, `false`, `yes`, `no`, `on`, `off`, `1`, `0`, `enabled`, `disabled`, in any case | anything else, `is not a boolean, use true or false` |
| `int` | a whole number, surrounding spaces trimmed | `abc is not a whole number` |
| `number` | a decimal number, surrounding spaces trimmed | `abc is not a number` |
| `string` | the text verbatim, and when the setting has an allowed list, one of those values exactly | a value outside the list, with the list as the hint |
| `csv` | the text verbatim, stored as one string | the same allowed-list check, though no `csv` setting declares one |
| `stringList` | comma separated, each item trimmed, empty text gives an empty list | nothing |
| `map` | nothing | always, `map settings cannot be set from the command line` |

The human output is the key and the value the store now holds. `--json` adds
what was there before, which is the fallback when the setting had never been
written:

```json
{
  "key": "creditHidden",
  "previous": false,
  "value": true
}
```

```
ed config set preventSleep true
ed config set warnPercent 70
ed config set limitsProvider codex
ed config set cleanerSelectedDrives /,/Volumes/Data
```

Validation happens before the write, so a rejected value leaves the stored value
alone and exits 1. The 23 read-only keys are refused the same way, also exit 1,
before anything is touched:

```
$ ed config set appearance bogus
error: bogus is not a valid value
hint: allowed: system, light, dark

$ ed config set micMuted true
error: micMuted is read only
```

A successful write posts `settingsChanged` whether or not Edith is running, so
`ed config set presenterMode true` blurs the numbers in the open window the same
way the menu bar toggle does.

## Where to go next

- [`ed config`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
