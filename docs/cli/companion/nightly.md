# `ed companion nightly`

Runs the whole nightly pipeline immediately. It syncs GitHub and Notion when
configured, indexes, rescales baselines, then runs claim extraction, entity and
fact resolution, corroboration, commitment tracking, calibration, reflection,
prediction resolution, hypothesis generation, core-memory rewriting, lens
rewriting and inquiry ranking. The command returns when the recorded run
finishes, which can take minutes on a slow reasoner.

Usage:

```
ed companion nightly [--json] [--endpoint <url>]
```

`--json` shape: `{"runId": "<uuid>"}`. Inspect the recorded steps with
`ed companion runs`.

Missing connector tokens record successful skipped connector steps. If no
reasoner is configured, the run records a successful `reasoning` skip and stops
after sync, indexing and baselines. Other step failures make the recorded run
unsuccessful but do not prevent later steps from being attempted. The CLI
request itself succeeds when the run was recorded; use `ed companion runs` to
inspect its `ok` value.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
