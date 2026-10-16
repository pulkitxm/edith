# `ed machines docker compose restart`

Restarts a compose project.

```
ed machines docker compose restart [--json] <machine> <project>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to act on. |
| `<project>` | compose project name, exactly as `compose ls` prints it | required | Which project to restart. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the one-line confirmation. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

## `--json` shape

```json
{
  "action": "restart",
  "machine": "Asus TUF 7",
  "project": "noveum-local-db"
}
```

## Examples

```
ed machines tuf docker compose restart noveum-local-db
ed machines tuf docker compose restart noveum-local-db --json
```

## Behaviour notes

Runs `docker compose -p <project> restart` with a 300 second ceiling, after the
same project check. This restarts the existing containers rather than recreating
them, so a changed compose file has no effect: that needs `up`. The Docker
window restarts containers one at a time and never a whole project, so this verb
has no button behind it.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
