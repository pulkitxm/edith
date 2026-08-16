# `ed machines docker rm`

Removes a container, killing it first.

```
ed machines docker rm [--json] <machine> <container>...
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to act on. |
| `<container>...` | one or more container names or ids | at least one required | Which containers to remove. Docker is given all of them in one call. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the one-line confirmation. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

## `--json` shape

```json
{
  "action": "rm",
  "containers": [
    "open-webui"
  ],
  "machine": "Asus TUF 7"
}
```

## Examples

```
ed machines tuf docker rm open-webui
ed machines tuf docker rm b556d7fef23e --json
```

## Behaviour notes

The remote command is `docker rm -f <container>`, so this kills a running
container and removes it in one step rather than refusing to touch it. There is
no `--yes` on this verb: it acts immediately, on the first try. The container's
writable layer goes with it, and anything the container wrote outside a volume
or a bind mount is gone. Named volumes survive, because `-v` is never passed.

Runs under a 120 second ceiling. Failure exits 1 with docker's stderr as the
hint. This is the Docker window's remove button, running the same command.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
