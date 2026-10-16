# `ed machines docker unpause`

Lets a frozen container run again.

```
ed machines docker unpause [--json] <machine> <container>...
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to act on. |
| `<container>...` | one or more container names or ids | at least one required | Which containers to resume. Docker is given all of them in one call. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the one-line confirmation. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

## `--json` shape

```json
{
  "action": "unpause",
  "containers": [
    "open-webui"
  ],
  "machine": "Asus TUF 7"
}
```

## Examples

```
ed machines tuf docker unpause open-webui
ed machines tuf docker unpause open-webui --json
```

## Behaviour notes

Runs `docker unpause <container>` under a 120 second ceiling. Unpausing a
container that is not paused exits 1 with docker's complaint as the hint.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
