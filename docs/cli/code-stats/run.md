# `ed code-stats run`

[`ed code-stats`](./README.md)

[The `ed` command line](../README.md)

```bash
ed code-stats run [--wait] [--json]
```

Starts a refresh in the background agent, or joins the one already running, since only one refresh runs at a time. The refresh reads your GitHub profile, lists your repositories, clones or fetches each one, counts your commits in parallel and stores a new report. The command refuses with exit code 4, and starts nothing, when the mirror folder is not chosen, missing, not writable or on a disconnected drive, or when `git` is missing. Without `--wait` the command returns the task id at once. `--wait` prints progress lines on stderr, then the outcome: `completed`, `cancelled`, `failed`, `storageUnavailable`, `volumeDisconnected` when the drive went away part way through, or `interrupted` when the background agent restarted during the refresh. `--json` prints that outcome as an object with the counts, the errors and a `github` field that is `null`, or names the `state` (`unavailable`, `signedOut` or `failed`) and a `summary` such as the `gh auth login` hint. The command exits 0 only when the refresh completed, and 1 for every other outcome. An empty identity list is filled from your GitHub profile first.
