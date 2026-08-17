# `ed machines services stop`

Stops one unit.

```
ed machines services stop <machine> <unit> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias or id | required | Which machine the unit lives on. |
| `<unit>` | unit name | required | The unit, for example `nginx.service`. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the human line. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

## `--json` shape

The same four keys, with `action` set to `stop`:

```json
{
  "action": "stop",
  "applied": true,
  "machine": "Asus TUF 7",
  "unit": "nginx.service"
}
```

## Examples

```
ed machines services stop tuf nginx.service
ed machines tuf services stop ollama.service
ed machines services stop tuf nginx.service --json
```

## Behaviour notes

The most disruptive command on this page that has no confirmation flag. Stopping
`ssh.service` on a machine you reach over SSH is the obvious way to lock
yourself out, and `ed` will not stop you.

The human success line is built by appending `ed` to the verb, so `stop` prints
`stoped nginx.service on Asus TUF 7`, with one `p`. Match on the JSON if you are
scripting against this, not on the prose.

Everything else matches `start`: same command shape with the verb swapped, same
60 second timeout, same failure handling and exit codes.

## Where to go next

- [`ed machines power`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
