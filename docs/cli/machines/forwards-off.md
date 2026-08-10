# `ed machines forwards off`

Closes a saved forward.

```
ed machines forwards off <machine> <index> [--json]
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
$ ed machines forwards off tuf 1
closed 127.0.0.1:3000:localhost:3000
```

## `--json` shape

The same object `on` emits, with `"open": false`.

## Examples

```
ed machines forwards off tuf 1
ed machines forwards off tuf 1 --json
```

## Behaviour notes

Sends `ssh -O cancel -L <spec>` and ignores what ssh says about it, so closing a
forward that was never open is reported as closed and exits 0 rather than being
treated as an error.

Like `on`, it opens the shared connection first. Closing a forward on a machine
that is currently disconnected therefore dials the machine to do nothing, and
exits 4 if it cannot.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
