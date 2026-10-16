# `ed app clear-updates`

Deletes the record of past update checks.

```
ed app clear-updates [--yes] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--yes` | flag | off | Delete the history. Without it, print the plan only. |
| `--json` | flag | off | Emit JSON on stdout. |

Without `--yes`, `--json` describes the safe preview, where `removed` is how
many checks would be removed:

```json
{
  "action": "clear update history",
  "applied": false,
  "changed": false,
  "removed": 42,
  "targets": ["/Users/me/Library/Application Support/Edith/update-checks.json"]
}
```

With `--yes`, `applied` is `true` and `changed` says whether the log contained
any checks.

Examples:

```
ed app clear-updates
ed app clear-updates --yes
ed app clear-updates --yes --json
```

Without `--yes` it prints the history file it would clear and changes nothing.
With `--yes` and without `--json` it prints `cleared 42 check(s)`. This is the
clear button in the update schedule sheet. It counts the file, deletes it, and
exits 0 whether or not there was anything to delete, reporting `cleared 0
check(s)` in the empty case. The file is removed outright rather than moved to
the Trash. Nothing else is touched, and neither process needs to be running.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
