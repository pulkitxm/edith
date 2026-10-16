# `ed machines docker restart`

Restarts a container.

```
ed machines docker restart [--json] <machine> <container>...
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to act on. |
| `<container>...` | one or more container names or ids | at least one required | Which containers to restart. Docker is given all of them in one call. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the one-line confirmation. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

## `--json` shape

```json
{
  "action": "restart",
  "containers": [
    "noveum-local-db-postgres-1"
  ],
  "machine": "Asus TUF 7"
}
```

## Examples

```
ed machines tuf docker restart noveum-local-db-postgres-1
ed machines tuf docker restart open-webui --json
```

## Behaviour notes

Runs `docker restart -t 10 <container>`, the same ten second grace period `stop`
uses, under the same 120 second ceiling. A container that takes longer than the
ceiling to come back leaves `ed` reporting a failure while docker carries on;
check with `ed machines docker ps` rather than assuming the restart was lost.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
