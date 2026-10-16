# `ed app updates`

Prints the update checks Edith has already made, newest first.

```
ed app updates [--limit <n>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--limit <n>` | integer greater than zero | `20` | Show at most this many checks. |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` shape, a top-level array with one object per check:

```json
[
  {
    "date": "2026-08-08T14:18:40Z",
    "detail": null,
    "kind": "manual",
    "outcome": "upToDate",
    "version": null
  },
  {
    "date": "2026-08-06T21:37:42Z",
    "detail": null,
    "kind": "automatic",
    "outcome": "updateFound",
    "version": "0.0.28"
  }
]
```

`kind` is `automatic` for a background check, which is both the scheduled ones
and every `ed app check-updates`, because the app answers that request with
Sparkle's background check. `manual` is the app's own Check for Updates button
and nothing `ed` can produce. `outcome` is `upToDate`, `updateFound` or
`failed`. `version` is filled in only on `updateFound`, `detail` only on
`failed`, and both are present as `null` otherwise so the shape does not change
between runs.

Examples:

```
ed app updates
ed app updates --limit 5
ed app updates --json
```

```
$ ed app updates --limit 5
WHEN                  KIND       OUTCOME      WHAT
2026-08-08T14:18:40Z  manual     upToDate     Up to date
2026-08-08T08:39:36Z  manual     upToDate     Up to date
2026-08-08T04:51:46Z  automatic  upToDate     Up to date
2026-08-07T13:42:03Z  automatic  upToDate     Up to date
2026-08-06T21:37:42Z  automatic  updateFound  Found 0.0.28
```

The `WHAT` column is a sentence built from the record: `Up to date`,
`Found <version>`, or the failure detail. A found update with no version reads
`Update found`, and a failure with no detail reads `Check failed`.

This is a file, `~/Library/Application Support/Edith/update-checks.json`, so it
needs nothing running. The app keeps the newest 200 checks and drops the rest,
and `ed` sorts by date descending before applying `--limit`. With no checks
recorded, it writes `no update checks recorded yet` to stderr, leaves stdout
empty and exits 0; with `--json` it prints `[]` instead.

`--limit 0` and `--limit=-1` exit 2 with `--limit must be greater than zero`.
Written as `--limit -1`, ArgumentParser reads the `-1` as another option and
exits 2 for a missing value instead, which is the same code by a different
route.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
