# `ed code-stats status`

[`ed code-stats`](./README.md)

[The `ed` command line](../README.md)

```bash
ed code-stats status [--json]
```

Shows whether the mirror folder is ready, missing, not writable or on a disconnected drive, the schedule, the identities counted as you, whether `git` and `gh` are installed and whether the last refresh found `gh` signed out, the GitHub accounts the last refresh read, the outcome of the last refresh, when the report was last updated, the next scheduled refresh, and the phase and counts of a refresh that is running. `--json` prints the same fields, including `storage.state`, `logins`, `running`, `taskID`, `progress`, `lastRun` (with its `github` state and summary) and `waitingFor`.
