# `ed agent`

`ed agent` inspects Edith's app-owned background services and job queue. They
run in the same process as the window, menu bar, and downloaded extension
engines. Jobs and subscriptions belong to this Edith installation.

Closing the window keeps enabled background work running. Quitting the whole
app stops it. The production app's Login Item controls whether Edith starts at
login; there is no separate background-agent LaunchAgent to register.

Every job declares a trigger, an ambient cadence that runs with no window open,
a live cadence that applies while something is subscribed to its topic, and a
power policy. `ed agent jobs` prints that table as the agent currently sees it.

## At a glance

| Command | What it does |
| --- | --- |
| [`ed agent status`](./status.md) | Registration state, build, uptime, memory, CPU and store schema |
| [`ed agent activity`](./activity.md) | Observed coding sessions and pending permission requests |
| [`ed agent jobs`](./jobs.md) | The live job table with triggers, cadences and subscribers |
| [`ed agent restart`](./restart.md) | Restart the app-owned core services |
| [`ed agent logs`](./logs.md) | Recent agent log lines from the unified log |
| [`ed agent events`](./events.md) | Retained structured runtime events and task IDs |
| [`ed agent run`](./jobs.md) | Queue a registered recurring job immediately |
| [`ed agent cancel`](./jobs.md) | Request cancellation of a recurring job |
| [`ed agent tasks`](./tasks.md) | Submit, inspect and cancel durable background tasks |
| [`ed agent schedule`](./schedule.md) | Run commands on an interval or a cron schedule, kept across restarts |

## Where to go next

- [`ed app`](../app/README.md), for the app window and menu bar
- [All `ed` commands](../README.md)
