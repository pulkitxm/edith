# `ed companion weekly`

The wider pass. The nightly run works on what just happened; this one looks across
weeks for what a single night cannot see, and it is what keeps the belief set from
only ever growing.

Usage:

```
ed companion weekly [--json] [--endpoint <url>]
```

Three things happen:

- Beliefs get **related** to each other as `supports`, `tensions_with` or `refines`,
  so the model of you has structure rather than being a flat list.
- Anything that tensions with something else is **reopened as contested**, which is
  what feeds the question ledger: a contested belief is a hole the system knows it
  has.
- Beliefs that have sat active for a month and have never once been retrieved are
  **retired**. Retired, not deleted.

`--json` shape: `{beliefsExamined, linksMade, contestedReopened, retired}`.

## Where to go next

- [`ed companion nightly`](./nightly.md), the pass that runs every night
- [`ed companion db`](./db.md), the monthly rebuild from the episodes
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
