# `ed machines workspace use`

Makes one workspace the current one.

Usage:

```
ed machines workspace use <workspace> [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<workspace>` | name, id, or unambiguous name prefix | required | Which workspace to switch to. Case-insensitive. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

`--json` shape, the same object `ls` emits for one row, with `current` always
true because it just became so:

```json
{
  "current": true,
  "id": "A494FD58-CB43-4068-8325-655E86794590",
  "machines": 2,
  "name": "Compare",
  "panes": 2
}
```

Examples:

```
ed machines workspace use Compare
ed machines workspace use comp
ed machines workspace use A494FD58-CB43-4068-8325-655E86794590
ed machines workspace use Compare --json
```

```
$ ed machines workspace use Compare
now showing Compare
```

Behaviour: `use` writes the current pointer and nothing else; the layout itself
is untouched. Names resolve in a fixed order: an exact case-insensitive name
first, then the id, then a unique case-insensitive name prefix. A prefix that
matches more than one workspace exits 3 and lists the matches rather than
guessing, and a name that matches none exits 3 with every known name as the
hint:

```
$ ed machines workspace use nope
error: no workspace called nope
hint: known: Compare
```

Running `use` when no workspaces are saved exits 4, because there is nothing to
switch to rather than something you named wrongly.

## Where to go next

- [`ed machines workspace`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
