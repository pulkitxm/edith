# `ed companion machines`

The companion backend's own machine inventory and multi-host placement planner.
Every machine is asked what it is rather than assumed to be anything, a
capability tier is derived from the answer, and you can override it.

This registry is stored in the companion database. It is separate from Edith's
`ed machines` fleet, [`ed companion hosts`](./hosts.md), the locally saved
deployment record, and [`ed companion deploy`](./deploy.md). These commands
plan topology but do not start, stop or move the currently deployed stack.

Usage:

```
ed companion machines [ls] [--json] [--endpoint <url>]
ed companion machines add <name> [--transport local|ssh|context] [--at <endpoint>]
                          [--json] [--endpoint <url>]
ed companion machines probe <name> [--json] [--endpoint <url>]
ed companion machines plan [--json] [--endpoint <url>]
ed companion machines profile <name> <tier> [--json] [--endpoint <url>]
```

`ed companion machines ls` (also the bare default) lists every machine registered,
its derived tier and what the probe found, in plain language.

`add` defaults to the `local` transport. For `ssh`, `--at` is `user@host`; for
`context`, it is a Docker context name. Omitting `--at` sends an empty endpoint
and lets the backend validate or use the transport default. JSON output confirms
only `{name,transport}`.

`ed companion machines probe` runs a small detection script over the transport and
records macOS architecture, container runtime and Compose versions, processor model,
cores, memory, free disk and which of the stack's ports are already taken.

The tiers:

| Tier | Condition | What it means |
| --- | --- | --- |
| `apple-metal` | macOS on Apple silicon | Containers cannot reach the GPU, so model services run on the host and containers reach them over the host address. |
| `cpu-only` | Intel Mac | Slow, and it boots. Degraded loudly rather than refused. |

`cpu-only` working is the point rather than an afterthought: it is what most people
trying this repo will land on, and a stack that needs a GPU to start gets one run.

`ed companion machines plan` proposes the placement before anything is touched: one
machine holds the core, Apple silicon hosts the models, and workers run wherever
there is capacity. It prints the compose files it would use and every
warning it found: a full disk, a taken port, and the reminder that Compose is a single
host tool, so several machines mean one stack each wired by explicit URLs. Bind the
database to a private or WireGuard address, never to a public interface.

`--json` shape for `plan`: `{compose, warnings, placements: [{machine, service, role,
enabled, notes}]}`.

List and probe JSON represent optional numeric machine facts such as `vramMb`,
`cpuCores`, `ramMb` and `diskFreeMb` as strings when present. `profile` is the
effective tier after any override. `profile` accepts only `apple-metal` or
`cpu-only`; it changes planning metadata and does
not redeploy containers.

## Where to go next

- [`ed companion doctor`](./doctor.md), whether what is placed is actually healthy
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
