# `ed machines disconnect`

Closes the shared SSH connection to a machine.

```
ed machines disconnect <machine> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the line. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines disconnect tuf
disconnected
```

## `--json` shape

```json
{
  "connected": false,
  "machine": "Asus TUF 7"
}
```

## Examples

```
ed machines disconnect tuf
ed machines disconnect tuf --json
```

## Behaviour notes

This is the one connection verb that does not dial: it resolves the machine,
sends `ssh -O exit` down the control socket, and deletes the socket file. A
machine that was not connected is reported as disconnected and exits 0, rather
than being treated as an error.

It closes the connection the app shares, so any port forwards opened with
`ed machines forwards on` go down with it, and the app's own Machines view
reconnects the next time it needs to.

An unknown machine name exits 3. Nothing else here can fail.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
