# `ed machines docker top`

Reads the processes running inside one container, using the same command and
parser as the app's Processes tab.

```
ed machines docker top <machine> <container> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or unambiguous prefix | required | Which machine to ask. |
| `<container>` | container name or id | required | Which container's processes to read. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit a stable array instead of the process table. |
| `--help`, `-h` | flag | off | Print help and exit 0. |

Plain output has PID, user, CPU, memory and command columns. JSON uses the stable
keys `pid`, `user`, `cpuPercent`, `memoryPercent` and `command`. Percentage
values remain strings because docker may return platform-specific sentinel text.

The shared operation first requests explicit process columns and falls back to
the platform's default `docker top` layout. It has a 30 second timeout and keeps
the order docker returns.

## Examples

```
ed machines docker top tuf api
ed machines docker top tuf api --json | jq -r '.[] | [.pid, .command] | @tsv'
```

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
