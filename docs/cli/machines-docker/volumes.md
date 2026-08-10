# `ed machines docker volumes`

Lists the volumes on the machine.

```
ed machines docker volumes [--json] <machine>
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
$ ed machines tuf docker volumes
NAME                                                              DRIVER  MOUNTPOINT
7a438a4d027cfca045e0fcb4caa787c1e26e70ef7839917dce8b768da5a4fc38  local   /var/lib/docker/volumes/7a438a4d027cfca045e0fcb4caa787c1e26e70ef7839917dce8b768da5a4fc38/_data
crowdvolt_postgres_data                                           local   /var/lib/docker/volumes/crowdvolt_postgres_data/_data
noveum-local-db_postgres_data                                     local   /var/lib/docker/volumes/noveum-local-db_postgres_data/_data
open-webui                                                        local   /var/lib/docker/volumes/open-webui/_data
pg_data                                                           local   /var/lib/docker/volumes/pg_data/_data
```

## `--json` shape

```json
[
  {
    "containers": null,
    "driver": "local",
    "inUse": false,
    "mountpoint": "/var/lib/docker/volumes/pg_data/_data",
    "name": "pg_data",
    "sizeBytes": null
  }
]
```

`sizeBytes`, `containers` and `inUse` are part of the shape the app's Docker
window fills in, and the CLI never fills them: it runs `docker volume ls` only,
never `docker system df -v`, so `sizeBytes` and `containers` are always `null`
and `inUse` is always `false`. The keys are present rather than dropped, so the
document shape does not change between runs. For real volume sizes use
`ed machines docker df`, which reports the total and reclaimable figures for
`Local Volumes`.

## Examples

```
ed machines tuf docker volumes
ed machines tuf docker volumes --json | jq -r '.[].name'
ed machines tuf docker volumes --json | jq -r '.[] | select(.name | startswith("noveum")) | .mountpoint'
```

## Behaviour notes

Read only, 45 second ceiling, `docker volume ls --format '{{json .}}'`. An
anonymous volume is listed under its 64 character hash, which is exactly the
name `volume-rm` wants.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
