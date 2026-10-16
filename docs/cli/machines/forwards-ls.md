# `ed machines forwards ls`

Lists the port forwards saved for a machine. These are the rows the machine's
Tools tab shows. `list` is an accepted alias, and `ls` is the group's default,
so `ed machines forwards <machine>` runs it. The group itself answers to
`forward` as well as `forwards`.

```
ed machines forwards ls <machine> [--json]
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

Forwards are sorted by local port ascending and numbered from 1 in that order.
That number is what `on`, `off` and `rm` take:

```
$ ed machines forwards ls tuf
#  TITLE  LOCAL  REMOTE
1         3000   localhost:3000
```

A machine with none prints `Asus TUF 7 has no saved forwards` on stderr and
exits 0 with an empty stdout.

## `--json` shape

A top-level array, empty when there are none:

```json
[
  {
    "id": "9017538C-E5A7-433A-9CCC-3BB55B7B57AA",
    "index": 1,
    "localPort": 3000,
    "remoteHost": "localhost",
    "remotePort": 3000,
    "spec": "127.0.0.1:3000:localhost:3000",
    "title": "localhost:3000 → localhost:3000"
  }
]
```

`index` is the number you pass to the other verbs. `spec` is the exact
`-L` argument `ed` hands to ssh. `title` is the display name, so an untitled
forward reports a generated `localhost:<local> → <host>:<remote>` string here
while the table's TITLE column shows the raw title and stays blank.

## Examples

```
ed machines forwards ls tuf
ed machines forwards tuf
ed machines forwards ls tuf --json | jq -r '.[] | "\(.index) \(.spec)"'
```

## Behaviour notes

Read only, and it reads `forwards.json` without dialling the machine, so it says
nothing about whether a forward is currently open. Only `on` and `off` know
that, and they do not record it.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
