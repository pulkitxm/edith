# `ed system agents`

Lists the local processes that Edith treats as coding-agent processes, or stops
one by PID. This command is independent of Edith and works with the app closed.

```
ed system agents ls [--limit <n>] [--json]
ed system agents kill [--force] <pid> [--json]
```

## `ls`

The list is sampled twice over 250 milliseconds. Human output is a table:

```
$ ed system agents ls
PID    NAME   CPU  MEMORY MB
4217   node   18.2  312.4
```

`--limit` keeps the first rows after sorting by CPU descending. Pass `0` to
show every recognized process. `--json` returns an array of objects with
`pid`, `name`, `cpuPercent` and `memoryMB`.

The list uses the same recognized process-name filter as Edith's system view.

## `kill`

`kill <pid>` validates that the PID currently belongs to a recognized agent and
sends SIGTERM. `kill --force <pid>` sends SIGKILL. The command refuses to signal
the `ed` process or a process outside the recognized list.

## Exit codes

| Code | When |
| --- | --- |
| 0 | The list was printed or the signal was sent. |
| 1 | The operating system refused the signal. |
| 2 | The PID or flag syntax was invalid. |
| 3 | The PID is not a recognized agent process. |

## Where to go next

- [`ed system`](./README.md) for machine metrics and mounted volumes
- [`ed apps`](../apps/README.md) for ordinary application windows
- [All `ed` commands](../README.md)
