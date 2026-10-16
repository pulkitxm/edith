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
records OS, architecture, container runtime and Compose versions, GPU vendor and
model, VRAM, cores, memory, free disk, whether a container can actually claim the GPU,
and which of the stack's ports are already taken. A card that is present but whose
runtime does not work is not a GPU machine, and the probe checks rather than trusting.

The tiers:

| Tier | Condition | What it means |
| --- | --- | --- |
| `gpu-large` | 24GB VRAM or more, runtime working | Large vision and speech models, reranking, all in containers. |
| `gpu-small` | 8 to 24GB VRAM, runtime working | Mid sized vision model, `large-v3` speech, in containers. |
| `apple-metal` | macOS on Apple silicon | Containers cannot reach the GPU, so model services run on the host and containers reach them over the host address. |
| `cpu-only` | anything else | Slow, and it boots. Degraded loudly rather than refused. |

`cpu-only` working is the point rather than an afterthought: it is what most people
trying this repo will land on, and a stack that needs a GPU to start gets one run.

`ed companion machines plan` proposes the placement before anything is touched: one
machine holds the core, the machine with the most VRAM holds the models, workers run
wherever there is capacity. It prints the compose files it would use and every
warning it found: a full disk, a taken port, and the reminder that Compose is a single
host tool, so several machines mean one stack each wired by explicit URLs. Bind the
database to a private or WireGuard address, never to a public interface.

`--json` shape for `plan`: `{compose, warnings, placements: [{machine, service, role,
enabled, notes}]}`.

List and probe JSON represent optional numeric machine facts such as `vramMb`,
`cpuCores`, `ramMb` and `diskFreeMb` as strings when present. `profile` is the
effective tier after any override. `profile` accepts only `gpu-large`,
`gpu-small`, `apple-metal` or `cpu-only`; it changes planning metadata and does
not redeploy containers.

## Where to go next

- [`ed companion doctor`](./doctor.md), whether what is placed is actually healthy
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
