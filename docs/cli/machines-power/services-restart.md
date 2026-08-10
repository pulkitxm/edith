# `ed machines services restart`

Restarts one unit.

```
ed machines services restart <machine> <unit> [--json]
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

```
$ ed machines services restart tuf nginx.service
restarted nginx.service on Asus TUF 7
```

## `--json` shape

```json
{
  "action": "restart",
  "applied": true,
  "machine": "Asus TUF 7",
  "unit": "nginx.service"
}
```

## Examples

```
ed machines services restart tuf nginx.service
ed machines tuf services restart docker.service
ed machines services restart tuf nginx.service --json
```

## Behaviour notes

`systemctl restart` on a stopped unit starts it, so this is the verb to reach
for when you do not care what state the unit was in. The 60 second timeout is
the one to watch: a unit with a slow `ExecStop` can outlast it, and the command
then reports a failure for something that finishes fine a moment later.

Only `start`, `stop` and `restart` exist. There is no `enable`, `disable`,
`reload`, `status` or `journal` verb; for those, use the raw form,
`ed tuf systemctl reload nginx` or `ed tuf journalctl -u nginx -n 100`.

## Where to go next

- [`ed machines power`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
