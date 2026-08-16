# `ed companion commitments`

What you said you would do, and what the record says happened. Commitments come out
of claims: anything you framed as an intention gets an observable attached and a due
date, then resolves later against what the connectors saw.

Usage:

```
ed companion commitments [--limit <n>] [--json] [--endpoint <url>]
```

Status is one of `open`, `met`, `partial`, `missed` or `invalidated`. Invalidated
means the records show the thing stopped being the right thing to do, which is a
different fact from not doing it.

`--json` shape: an array of `{id, claim, statedAt, dueBy, status, resolvedAt,
userOverride}`.

`--limit` defaults to 20, must be positive, and is capped at 500 by the backend.

One instance is noise. Two hundred is a calibration curve, and that is the point:
see [`ed companion standup report`](./standup.md) for what they add up to.

## Where to go next

- [`ed companion discrepancies`](./discrepancies.md), where your account and the record parted company
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
