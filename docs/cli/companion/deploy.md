# `ed companion deploy`

Chooses the machine that runs the companion, brings the stack up there, and
remembers the choice so everything else knows where it lives.

Usage:

```
ed companion deploy [<machine>] [--directory <path>] [--port <n>] [--adopt] [--build] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--directory` | path | `~/edith-companion` | Where the stack runs on that machine. |
| `--port` | number | 4820 | Local port the API is reached on. |
| `--adopt` | flag | off | Records a stack that is already running without starting anything. |
| `--build` | flag | off | Rebuilds the api image first. |

With no machine argument it uses the one that already hosts the stack, or the
best candidate that can run it.

Examples:

```
$ ed companion deploy "TUF Wired"
the companion running on TUF Wired, cpu, reached on port 4820

$ ed companion deploy "TUF Wired" --adopt
the companion running on TUF Wired, cpu, reached on port 4820
```

A machine that cannot run it yet is refused with the reason and the fix, so
nothing half-starts. The tier is derived from what the host actually has: a GPU
box gets the GPU overlay, a Mac gets the Apple one, everything else gets CPU.

## Where to go next

- [`ed companion hosts`](./hosts.md) shows the candidates first.
- [`ed companion stack`](./stack.md) drives it once it is deployed.

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
