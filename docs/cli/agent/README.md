# `ed agent`

`ed agent` inspects and controls `edithd`, the headless background agent Edith
registers as a LaunchAgent. The agent owns collection and long jobs: usage and
limits, session discovery, machine health and metrics, update discovery, the
cleaner estimate, the download queue, Memory health, site audits and the iCloud
backup scheduler. It runs with no windows and never asks for a permission.

launchd starts the agent on demand through its Mach service,
`com.pulkit.edith.agent`, and keeps it alive while its Login Items entry is
enabled. The app registers it with `SMAppService` on launch; macOS may hold the
registration in Login Items and Extensions until you approve it, which is what
`awaitingApproval` means.

Every job declares a trigger, an ambient cadence that runs with no window open,
a live cadence that applies while something is subscribed to its topic, and a
power policy. `ed agent jobs` prints that table as the agent currently sees it.

## At a glance

| Command | What it does |
| --- | --- |
| [`ed agent status`](./status.md) | Registration state, build, uptime, memory, CPU and store schema |
| [`ed agent jobs`](./jobs.md) | The live job table with triggers, cadences and subscribers |
| [`ed agent restart`](./restart.md) | Stop the agent so launchd starts it again |
| [`ed agent logs`](./logs.md) | Recent agent log lines from the unified log |

## Where to go next

- [`ed app`](../app/README.md), for the window and the menu bar helper
- [All `ed` commands](../README.md)
