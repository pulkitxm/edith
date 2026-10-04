# `ed code-stats`

`ed code-stats` drives the Code Stats ability, the same one the Code Stats settings and page use. Edith mirrors every GitHub repository you can reach into a folder you choose, counts the commits that are yours across all of them, and keeps a report of commits, lines, streaks, languages and habits. The background agent owns the mirror and the report, so the status, run, cancel, report and authors commands need Edith or `edithd` running. The folder, schedule and identity commands write the shared settings directly.

[The `ed` command line](../README.md)

| Command | What it does |
| --- | --- |
| [`ed code-stats status`](./status.md) | Shows the folder, schedule, last refresh and live progress. |
| [`ed code-stats run`](./run.md) | Refreshes the mirror and recounts your commits. |
| [`ed code-stats cancel`](./cancel.md) | Cancels the refresh in progress. |
| [`ed code-stats report`](./report.md) | Prints the report for 30 days, 90 days, a year or all time. |
| [`ed code-stats folder`](./folder.md) | Chooses the folder that holds the mirror. |
| [`ed code-stats schedule`](./schedule.md) | Chooses a manual, daily or weekly refresh. |
| [`ed code-stats identity`](./identity.md) | Lists, adds and removes the identities counted as you. |
| [`ed code-stats authors`](./authors.md) | Lists the commit authors found in the mirror. |

`status` is the default, so a bare `ed code-stats` shows the status. `identity` defaults to `identity list`.

## How it works

- Repositories are listed with the GitHub CLI (`gh`), so run `gh auth login` once. Without `gh` the agent still analyses whatever is already in the folder.
- New repositories are cloned bare into `<folder>/<owner>/<repo>.git` and existing ones are fetched. Clones made by other tools as `<folder>/<owner>/<repo>/.git` are read as they are. Nothing in the folder is ever deleted.
- Results and the per-repository cache live in Edith's own data folder, not in the mirror, so the last report stays readable while an external drive is unplugged.
- A folder on an external drive under `/Volumes` is remembered while the drive is away. A scheduled refresh that comes due then waits for the drive, and runs once when it returns. The schedule counts from the first refresh you start, even one that the drive cut short.
- Forks are skipped and archived repositories are included unless you change `codeStatsIncludeForks` or `codeStatsIncludeArchived` with `ed config set`.

## Exit codes

| Code | When |
| --- | --- |
| 0 | the command completed |
| 2 | a range, schedule, hour or weekday was not valid |
| 3 | the folder does not exist, an identity to remove is not listed, or no report exists yet |
| 4 | the background agent is not running |
