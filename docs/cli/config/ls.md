# `ed config ls`

Lists settings with their group, type and current value, in catalogue order.

```
ed config ls [<prefix>] [--group <group>] [--changed] [--json]
```

| Argument | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `prefix` | string | none, every setting | Only settings whose key starts with this text. Matched case-sensitively, so `notch` matches and `Notch` does not |

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--group` | one of `appearance`, `panel`, `usage`, `limits`, `menubar`, `alerts`, `budget`, `dashboard`, `machines`, `finder`, `system`, `cleaner`, `music`, `calendar`, `clipboard`, `notch`, `focusdim`, `presenter`, `colorpicker`, `micmute`, `backup`, `permissions`, `terminal` | none | Only settings in this group |
| `--changed` | flag | `false` | Only settings that differ from their default |
| `--json` | flag | `false` | Emit JSON on stdout |

The three filters compose: prefix first, then group, then changed.

`--json` emits an array of the same object `get` and `describe` emit, one per
setting, in catalogue order. Keys inside each object are sorted.

```json
[
  {
    "allowed": [
      "system",
      "light",
      "dark"
    ],
    "default": "system",
    "group": "appearance",
    "isSet": false,
    "key": "appearance",
    "readOnly": false,
    "scope": "shared",
    "summary": "Window and panel appearance.",
    "type": "string",
    "value": "system"
  },
  {
    "allowed": [],
    "default": "default",
    "group": "appearance",
    "isSet": false,
    "key": "theme",
    "readOnly": false,
    "scope": "shared",
    "summary": "Accent palette name.",
    "type": "string",
    "value": "default"
  }
]
```

```
ed config ls
ed config ls --group limits
ed config ls clipboardHotKey
ed config ls --changed --json
```

Reading changes nothing and needs nothing. A group that is not one of the 23
exits 3 and lists them all. A prefix that matches no key exits 3, unless the
prefix is the name of a sibling subcommand, which exits 2 instead of pretending
you meant a setting:

```
$ ed config ls get
error: get is a subcommand, not a setting prefix

$ ed config ls exp
error: no setting starts with exp
hint: did you mean `ed config export`?
```

## Where to go next

- [`ed config`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
