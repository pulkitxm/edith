# `ed machines docker compose logs`

Streams the logs of every container in a compose project.

```
ed machines docker compose logs [--tail <n>] [--follow] <machine> <project>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to ask. |
| `<project>` | compose project name, exactly as `compose ls` prints it | required | Whose logs to stream. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tail` | integer, 0 or more | `200` | How many trailing lines to show, per service. |
| `--follow`, `-f` | flag | off | Keep streaming until interrupted. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

There is no `--json`, and unlike `ed machines docker logs` there are no
timestamps: compose prefixes each line with the service name instead.

## Examples

```
ed machines tuf docker compose logs noveum-local-db
ed machines tuf docker compose logs noveum-local-db --tail 20
ed machines tuf docker compose logs noveum-local-db --tail 0 --follow
```

## Behaviour notes

The remote command is `docker compose -p <project> logs --tail <n> [-f]`, after
the same project check the other compose verbs make, so an unlisted project
exits 3 before anything streams. `--tail` is validated first and a negative
value exits 2.

Like `ed machines docker logs`, this is a passthrough: stdout and stderr stay
separate, there is no timeout, and the remote exit code becomes yours.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
