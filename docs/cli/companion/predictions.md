# `ed companion predictions`

What the companion expects to happen, and what actually did. Each prediction belongs
to a hypothesis, names exactly what record would confirm or deny it, and carries a
window it must resolve inside.

Usage:

```
ed companion predictions [--limit <n>] [--json] [--endpoint <url>]
```

An open prediction prints the date its window closes. A resolved one prints
`confirmed`, `denied` or `unresolvable`. The resolver is instructed to treat absent
records as `unresolvable`, not `denied`, though the backend accepts any of those three
valid outcomes returned by the reasoning provider without a separate evidence check.

`--json` shape: an array of `{id, hypothesisId, statement, observable, windowStart,
windowEnd, resolvedAt, outcome}`.

`--limit` defaults to 20 and must be positive.

## Where to go next

- [`ed companion hypotheses`](./hypotheses.md), the theories these test
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
