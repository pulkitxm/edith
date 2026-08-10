# `ed machines docker stop`

Stops a running container.

```
ed machines docker stop [--json] <machine> <container>...
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to act on. |
| `<container>...` | one or more container names or ids | at least one required | Which containers to stop. Docker is given all of them in one call. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the one-line confirmation. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

## `--json` shape

```json
{
  "action": "stop",
  "containers": [
    "open-webui"
  ],
  "machine": "Asus TUF 7"
}
```

## Examples

```
ed machines tuf docker stop open-webui
ed machines tuf docker stop open-webui --json
```

## Behaviour notes

Runs `docker stop -t 10 <container>...`, so each container gets ten seconds to
exit on its own before docker kills it. The stop button on a group header in the
Docker window is this command with the group's running and paused containers
named. The whole call has a 120 second ceiling.
Stopping a container that is already stopped is docker's business and succeeds
quietly. Failure exits 1 with docker's stderr as the hint.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
