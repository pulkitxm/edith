# `ed machines docker ps`

Lists containers, merging `docker ps -a` with a one-shot `docker stats` so each
row carries live CPU and memory next to its state and ports. It is the group's
default subcommand, so `ed machines docker <machine>` runs it.

```
ed machines docker ps [--json] [--all] <machine>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to ask. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the table. Long form only, there is no `-j`. |
| `--all`, `-a` | flag | off | Include containers that are not running. Without it only `running` and `restarting` containers are listed. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

The table prints its headings even when nothing matches:

```
$ ed machines tuf docker ps
ID  NAME  IMAGE  STATE  CPU  PORTS

$ ed machines tuf docker ps --all
ID            NAME                          IMAGE                               STATE   CPU  PORTS
b556d7fef23e  lobe-chat                     lobehub/lobe-chat:latest            exited  -
f8968a8b81e5  open-webui                    ghcr.io/open-webui/open-webui:main  exited  -
47e37ace9821  noveum-local-db-postgres-1    postgres:17-alpine                  exited  -
efe6aaaae124  noveum-local-db-clickhouse-1  clickhouse/clickhouse-server:24.12  exited  -
5477a5a28510  noveum-local-db-redis-1       redis/redis-stack:latest            exited  -
```

With the same containers running, the `CPU` and `PORTS` columns fill in and the
stopped rows are gone:

```
$ ed machines tuf docker ps
ID            NAME                          IMAGE                               STATE    CPU    PORTS
b556d7fef23e  lobe-chat                     lobehub/lobe-chat:latest            running  0.0%
f8968a8b81e5  open-webui                    ghcr.io/open-webui/open-webui:main  running  0.3%   3000 → 8080/tcp
47e37ace9821  noveum-local-db-postgres-1    postgres:17-alpine                  running  2.7%   5433 → 5432/tcp
```

`CPU` reads `-` when `docker stats` had nothing to say about that container,
which is every stopped container and, briefly, one that has just started.

## `--json` shape

A top-level array, one object per container, in the order docker listed them.
This is a real document trimmed to one entry:

```json
[
  {
    "command": "\"docker-entrypoint.sh postgres\"",
    "composeProject": "noveum-local-db",
    "composeService": "postgres",
    "cpuPercent": null,
    "createdAt": "2026-08-05 22:28:30 +0530 IST",
    "health": "none",
    "id": "47e37ace98211bfcf5d14f4f6e80e4d76b09c30914cb8e8ecf7e14cc029f237e",
    "image": "postgres:17-alpine",
    "memLimitBytes": null,
    "memUsedBytes": null,
    "name": "noveum-local-db-postgres-1",
    "names": [
      "noveum-local-db-postgres-1"
    ],
    "ports": [],
    "shortID": "47e37ace9821",
    "state": "exited",
    "status": "Exited (0) 2 hours ago"
  }
]
```

What the fields mean:

- `id` is the full container id, because `docker ps` runs with `--no-trunc`.
  `shortID` is its first twelve characters, which is what the table prints and
  what every other verb here accepts.
- `name` is the first of `names`; `names` holds all of them, since a container
  can carry several. A container with no name at all falls back to `shortID`.
- `state` is one of `created`, `running`, `paused`, `restarting`, `exited`,
  `dead`, `removing`, or `unknown` when docker reports something newer than
  that list. `status` is docker's own sentence, such as `Exited (0) 2 hours
  ago`.
- `health` is `none`, `starting`, `healthy` or `unhealthy`. It comes from
  docker's `HealthStatus` field, falling back to reading `(healthy)`,
  `(unhealthy)` or `health: starting` out of `status`. A container with no
  health check reports `none`.
- `ports` is an array of strings, each rendered as `5433 → 5432/tcp` with a
  literal arrow, or as `5432/tcp` alone when the port is exposed but not
  published. Do not expect `->`. Duplicate IPv4 and IPv6 mappings are collapsed
  into one entry, and the list is sorted by host port, with unpublished ports
  last.
- `composeProject` and `composeService` come from the
  `com.docker.compose.project` and `com.docker.compose.service` labels, and are
  `null` on a container compose did not create.
- `createdAt` is docker's own string, `2026-08-05 22:28:30 +0530 IST`. It is not
  ISO 8601, unlike dates elsewhere in `ed --json`.
- `command` is docker's quoted form, so the value usually contains its own
  quotation marks.
- `cpuPercent`, `memUsedBytes` and `memLimitBytes` come from `docker stats
  --no-stream` and are `null` for anything not running. `cpuPercent` is docker's
  own figure, summed across cores, so a busy container reads above 100.

## Examples

```
ed machines tuf docker ps
ed machines tuf docker ps --all --json
ed machines tuf docker ps --json | jq -r '.[] | select(.health == "unhealthy") | .name'
ed machines tuf docker ps --json | jq -r '.[] | "\(.name) \(.ports | join(","))"'
```

## Behaviour notes

Read only. The remote command is `docker ps -a --no-trunc --format '{{json .}}'`
followed by `docker stats --no-stream`, sent as one line with a separator
between them, with a 45 second ceiling. `docker stats` has its stderr thrown
away, so its noise never lands in the parse, and a container it says nothing
about is still listed with its stats null. Its exit status is the status of the
whole line, though, so a `docker stats` that fails outright takes the container
list down with it and exits 1.

`--all` is a client-side filter, not `docker ps` without `-a`: the machine
always returns every container and `ed` drops the ones that are neither
`running` nor `restarting`. The consequence worth remembering is that a paused
container does not appear without `--all`.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
