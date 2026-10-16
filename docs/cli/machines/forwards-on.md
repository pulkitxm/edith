# `ed machines forwards on`

Opens a saved forward on the shared connection, which is the switch on each row
of the Tools tab.

```
ed machines forwards on <machine> <index> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. |
| `<index>` | integer, counting from 1 | none | The forward's position in `ed machines forwards ls`. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the line. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines forwards on tuf 1
localhost:3000 now reaches localhost:3000
```

## `--json` shape

The forward object with one extra key:

```json
{
  "id": "9017538C-E5A7-433A-9CCC-3BB55B7B57AA",
  "index": 1,
  "localPort": 3000,
  "open": true,
  "remoteHost": "localhost",
  "remotePort": 3000,
  "spec": "127.0.0.1:3000:localhost:3000",
  "title": "localhost:3000 → localhost:3000"
}
```

## Examples

```
ed machines forwards on tuf 1
ed machines forwards on tuf 1 --json
```

## Behaviour notes

Opens the shared connection if it is not already up, then sends
`ssh -O forward -L 127.0.0.1:<local>:<remoteHost>:<remotePort>` down the control
socket. Nothing is written to disk, so which forwards are open is not recorded
anywhere: the tunnel lives as long as the connection does and
`ed machines disconnect` takes it with it.

A session the app is supervising is the exception, and this is the port forward
replay the mount section refers to. That session keeps the forwards it opened in
memory, and when it reconnects after a drop it opens them again, so a blip or a
sleeping laptop no longer costs you every tunnel. A forward whose replay fails
is dropped from the remembered set rather than retried forever. This belongs to
the app's session: a forward you opened with `ed machines forwards on` is not in
that set, so a reconnect does not bring it back and you open it again yourself.

The local end is bound to `127.0.0.1` only, so nothing else on your network can
reach through it.

A refusal from ssh, most often a local port already in use, exits 1 with ssh's
own message as the hint. An index outside the range exits 3; an unreachable
machine exits 4.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
