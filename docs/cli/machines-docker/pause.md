# `ed machines docker pause`

Freezes a container's processes without stopping it.

```
ed machines docker pause [--json] <machine> <container>...
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to act on. |
| `<container>...` | one or more container names or ids | at least one required | Which containers to freeze. Docker is given all of them in one call. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the one-line confirmation. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

## `--json` shape

```json
{
  "action": "pause",
  "containers": [
    "open-webui"
  ],
  "machine": "Asus TUF 7"
}
```

## Examples

```
ed machines tuf docker pause open-webui
ed machines tuf docker pause open-webui --json
```

## Behaviour notes

Runs `docker pause <container>` under a 120 second ceiling. The container keeps
its memory and its ports; its processes simply stop being scheduled.

A paused container reports `state: "paused"`, which `ed machines docker ps`
counts as not running, so it vanishes from a bare `ps` and only reappears with
`--all`. Pausing something already paused is an error on docker's side and exits
1.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
