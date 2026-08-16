# `ed extensions disable`

Turns one extension off.

```
ed extensions disable <id> [--json]
```

| Argument | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `id` | one of the fourteen ids, or a defaults key | required | The extension to turn off |

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit the extension's record on stdout instead of the one-line confirmation |

The same write in reverse: the key is set to `false`, the store is synchronised,
`settingsChanged` is posted. Permissions are not consulted at all, so there is
never a note, and `--json` emits the same record with `enabled` now `false`.

```
$ ed extensions disable notchShelf
notchShelf disabled
```

```
ed extensions disable presenter
ed extensions disable colorPicker --json
```

Disabling only flips the switch. It does not revoke a macOS grant, does not
delete anything the extension collected, and does not stop the app: your
clipboard history, shelf and music library survive `disable` and come back when
you enable it again. Unknown ids exit 3, as everywhere else in this group.

## Where to go next

- [`ed extensions`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
