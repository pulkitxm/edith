# `ed machines docker networks`

Lists the docker networks on the machine.

```
ed machines docker networks [--json] <machine>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to ask. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the table. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines tuf docker networks
NAME                     DRIVER  SCOPE
bridge                   bridge  local
host                     host    local
none                     null    local
noveum-local-db_default  bridge  local
```

## `--json` shape

```json
[
  {
    "driver": "bridge",
    "id": "5b5aedee9cc4",
    "name": "bridge",
    "scope": "local"
  },
  {
    "driver": "bridge",
    "id": "a3f0be1c77d2",
    "name": "noveum-local-db_default",
    "scope": "local"
  }
]
```

`id` is the truncated twelve character id docker prints for networks, not the
full one: unlike `ps` and `images`, this command does not pass `--no-trunc`.

## Examples

```
ed machines tuf docker networks
ed machines tuf docker networks --json | jq -r '.[] | select(.driver == "bridge") | .name'
```

## Behaviour notes

Read only, 30 second ceiling, `docker network ls --format '{{json .}}'`. The
three built-in networks, `bridge`, `host` and `none`, are always listed and are
never touched by `prune networks`.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
