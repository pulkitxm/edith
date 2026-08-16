# `ed machines snippets ls`

Lists the saved commands a machine offers: the ones saved against it, plus every
shared one. `list` is an accepted alias, and `ls` is the group's default, so
`ed machines snippets <machine>` runs it. The group itself answers to `snippet`
as well as `snippets`.

```
ed machines snippets ls <machine> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the table. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

Snippets are numbered from 1 in the order they were saved. Nothing is sorted,
and shared snippets sit in the same numbering as this machine's own:

```
$ ed machines snippets ls studio
#  TITLE  SCOPE    COMMAND
1  logs   machine  log show --last 5m
```

A machine with none prints `Studio Mac has no snippets` on stderr and exits 0.

## `--json` shape

```json
[
  {
    "command": "log show --last 5m",
    "id": "F8D5CE93-C9B4-4A05-9109-9AEB1BD806BA",
    "index": 1,
    "sharedAcrossMachines": false,
    "title": "logs"
  }
]
```

`sharedAcrossMachines` is `true` for a snippet with no machine of its own, which
is the `shared` value in the SCOPE column.

## Examples

```
ed machines snippets ls studio
ed machines snippets studio
ed machines snippets ls studio --json | jq -r '.[] | select(.sharedAcrossMachines) | .title'
```

## Behaviour notes

Read only, straight out of `snippets.json`, with no connection opened. A snippet
is a saved string; nothing here runs it. To run one, pass it to
`ed machines exec` or the `ed <machine> ...` shorthand.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
