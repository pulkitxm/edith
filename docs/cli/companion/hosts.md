# `ed companion hosts`

Lists every machine that could run the companion, this Mac first, and says what
each one still needs. It answers the question "where would the containers run".

This command talks to your machines, not to the companion API, so it works when
the backend is not running anywhere yet.

Usage:

```
ed companion hosts [--json] [--machine <name>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--machine` | machine name | every machine | Probes only this one. |

A `*` marks the machine that currently hosts the stack.

Examples:

```
$ ed companion hosts
NAME                  TARGET            STATE                                         DETAIL
Pulkit's MacBook Pro  this Mac          Apple Container is installed but not running  darwin arm64 · 14 cores · 24 GB
* TUF Wired           pulkit@10.77.0.2  ready                                         linux x86_64 · 20 cores · 62 GB · Docker 29.7.1
the stack is running on TUF Wired, cpu, reached on port 4820
```

Each host reports its os, arch, cores, memory, free disk, GPU, which container
runtimes are installed and whether their daemon is running, and which of the
ports the stack needs are already taken. A machine that already hosts the stack
is not blocked by its own ports.

`--json` gives every fact plus a `blockers` array, each with a `headline` and
the `fix` that clears it.

## Where to go next

- [`ed companion deploy`](./deploy.md) picks the machine and brings it up.
- [`ed companion stack`](./stack.md) starts, stops and inspects it.

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
