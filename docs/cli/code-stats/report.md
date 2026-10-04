# `ed code-stats report`

[`ed code-stats`](./README.md)

[The `ed` command line](../README.md)

```bash
ed code-stats report [--range 30d|90d|1y|all] [--json]
```

Prints the report the last refresh stored for the range, 30 days by default: commits, lines authored and deleted, active days, current and longest streak, repositories touched, momentum against the previous period of the same length, and the top languages. `--json` prints the whole report, including the daily, weekly and monthly series, per-repository and per-language totals, the weekday by hour punchcard and the top days. Exits 3 when no refresh has finished yet.
