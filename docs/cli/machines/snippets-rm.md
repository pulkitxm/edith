# `ed machines snippets rm`

Forgets one snippet. `remove` is an accepted alias.

```
ed machines snippets rm <machine> <index> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. |
| `<index>` | integer, counting from 1 | none | The snippet's position in `ed machines snippets ls` for that machine. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the line. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

## `--json` shape

```json
{
  "remaining": 0,
  "removed": {
    "command": "log show --last 5m",
    "id": "F8D5CE93-C9B4-4A05-9109-9AEB1BD806BA",
    "index": 1,
    "sharedAcrossMachines": false,
    "title": "logs"
  }
}
```

`remaining` counts what that machine still offers, shared snippets included.

## Examples

```
ed machines snippets rm studio 1
ed machines snippets rm studio 1 --json
```

## Behaviour notes

Removes the snippet from `snippets.json` by id and posts `machinesChanged`.

The numbering includes shared snippets, so an index can name one that every
other machine also offers, and removing it removes it everywhere. Check
`sharedAcrossMachines` in the listing before you delete by number.

An index outside the range exits 3:

```
$ ed machines snippets rm studio 1
error: there is no snippet 1 on Studio Mac
hint: it offers 0, numbered from 1
```

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
