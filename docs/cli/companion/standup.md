# `ed companion standup`

Records a standup and, on request, checks what you said against what the record
shows. The per instance result is nearly worthless. The aggregate is the point.

Usage:

```
ed companion standup [record] <file|-> [--verify] [--json] [--endpoint <url>]
ed companion standup report [--json] [--endpoint <url>]
```

`ed companion standup record` (also the bare default) reads a transcript from a file
or stdin, stores it as an episode, and extracts the claims inside it: what you
finished, what you committed to, how you rated yourself. `--verify` goes further and
resolves those claims against the connectors, tracks the commitments and scores the
calibration.

`ed companion standup report` is the aggregate: how many standups, what share of
commitments landed, the median slip in days, and how often your account ran ahead of
or behind the record.

`--json` shape for `report`: `{standups, commitmentsResolved, metRate, medianSlipDays,
overstated, understated, invisibleWork, dueSoon}`.

Read it as a calibration mirror rather than a lie detector. Almost all standup
inflation is optimism, not deception, and optimism bias is the more actionable finding
because it is fixable and it is not shameful. When work happened somewhere the
connectors could not see, correct it with
[`ed companion discrepancies override`](./discrepancies.md).

## Where to go next

- [`ed companion commitments`](./commitments.md), what each standup put on the clock
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
