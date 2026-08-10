# `ed app clear-updates`

Deletes the record of past update checks.

```
ed app clear-updates [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` shape, where `removed` is how many checks were in the log before it
went:

```json
{
  "removed": 42
}
```

Examples:

```
ed app clear-updates
ed app clear-updates --json
```

Without `--json` it prints `cleared 42 check(s)`. This is the clear button in
the update schedule sheet. It counts the file, deletes it, and exits 0 whether
or not there was anything to delete, reporting `cleared 0 check(s)` in the empty
case.

It is the only destructive verb in this group and it takes no `--yes`, because
there is nothing behind the log: the file is removed outright rather than moved
to the Trash, and the checks it held are gone. Nothing else is touched, and
neither process needs to be running.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
