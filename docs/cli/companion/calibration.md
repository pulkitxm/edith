# `ed companion calibration`

How your account of yourself compares with the record, tracked in both directions and
scored separately per domain, because estimating work, judging yourself and reading
risk are different skills and you are probably not equally miscalibrated across them.

Usage:

```
ed companion calibration [--json] [--endpoint <url>]
```

Directions are `overstated`, `understated`, `signal_dismissed` and `accurate`.
Domains are `work_estimates`, `self_assessment`, `risk` and `general`.

`--json` shape: an array of `{domain, direction, samples, averageMagnitude}`.

The less obvious directions matter too. `understated` records when the record is
better than your account, while `signal_dismissed` records an override where the
available observations missed real work. This command reports the aggregate;
the current ask and chat retrieval paths do not inject it directly as a lens prior.

## Where to go next

- [`ed companion discrepancies`](./discrepancies.md), the individual divergences behind these numbers
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
