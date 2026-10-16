# `ed machines workspace rename`

Renames a workspace.

Usage:

```
ed machines workspace rename <workspace> <name> [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<workspace>` | name, id, or unambiguous name prefix | required | Which workspace to rename. Case-insensitive. |
| `<name>` | text | required | The new name. Leading and trailing whitespace is trimmed. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

`--json` shape, the renamed workspace:

```json
{
  "current": true,
  "id": "A494FD58-CB43-4068-8325-655E86794590",
  "machines": 2,
  "name": "Fleet",
  "panes": 2
}
```

Examples:

```
ed machines workspace rename Compare Fleet
ed machines workspace rename comp "Two machines"
ed machines workspace rename A494FD58-CB43-4068-8325-655E86794590 Fleet --json
```

```
$ ed machines workspace rename Compare Fleet
renamed Compare to Fleet
```

Behaviour: `rename` changes the name and nothing else. It captures which
workspace is current before it writes and puts it back afterwards, so renaming a
workspace you are not using does not switch you to it, unlike `new`.

A name that is empty or only whitespace is refused and exits 1 with
`a workspace needs a name`. The old name is not freed for anything: the file
allows duplicates, so renaming one workspace onto another's name is accepted and
leaves you with two rows that resolve to the first.

The `current` field in the JSON is read from the stored pointer rather than the
effective one. When no workspace has ever been made current, `ls` shows the
first row as current and `rename` reports `"current": false` for that same row.
Run `use` once if you want the two to agree.

## Where to go next

- [`ed machines workspace`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
