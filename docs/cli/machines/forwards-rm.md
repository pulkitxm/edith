# `ed machines forwards rm`

Forgets one saved forward. `remove` is an accepted alias.

```
ed machines forwards rm <machine> <index> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. |
| `<index>` | integer, counting from 1 | none | The forward's position in `ed machines forwards ls`, which is its rank by local port. |

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
    "id": "9017538C-E5A7-433A-9CCC-3BB55B7B57AA",
    "index": 1,
    "localPort": 3000,
    "remoteHost": "localhost",
    "remotePort": 3000,
    "spec": "127.0.0.1:3000:localhost:3000",
    "title": "localhost:3000 → localhost:3000"
  }
}
```

## Examples

```
ed machines forwards rm tuf 1
ed machines forwards rm tuf 2 --json
```

## Behaviour notes

Removes the row from `forwards.json` and posts `machinesChanged`. It does not
close the tunnel: a forward you opened with `on` keeps running on the shared
connection until you close it or the connection goes. Run `off` first if you
want it down.

An index outside the range exits 3 and tells you the range:

```
$ ed machines forwards rm tuf 4
error: there is no forward 4 on Asus TUF 7
hint: it has 1, numbered from 1
```

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
