# `ed code-stats run`

[`ed code-stats`](./README.md)

[The `ed` command line](../README.md)

```bash
ed code-stats run [--wait] [--json]
```

Starts a refresh in the background agent, or joins the one already running, since only one refresh runs at a time. The refresh reads your GitHub profile, lists your repositories, clones or fetches each one, counts your commits in parallel and stores a new report. Without `--wait` the command returns the task id at once. `--wait` prints progress lines on stderr and finishes with the outcome: `completed`, `cancelled`, `interrupted`, or `volumeDisconnected` when the drive went away part way through. An empty identity list is filled from your GitHub profile first.
