# `ed companion calibration`

How your account of yourself compares with the record, tracked in both directions and
scored separately per domain, because estimating work, judging yourself and reading
risk are different skills and you are probably not equally miscalibrated across them.

Usage:

```
ed companion calibration [--json] [--endpoint <url>]
```

Directions are `overstated`, `understated`, `worry_unrealized`, `signal_dismissed`
and `accurate`. Domains are `work_estimates`, `self_assessment`, `risk` and
`general`.

`--json` shape: an array of `{domain, direction, samples, averageMagnitude}`.

The last two directions are the ones worth having. Anyone can point out that you are
behind schedule. Noticing that you keep mentioning something you insist does not
matter, or that a risk you have flagged five times has materialised once, is a
different order of attention. This profile feeds the lenses as a prior: when the
skeptic decides whether to push, "his self-criticism runs harsher than the record
supports" is exactly the input it needs.

## Where to go next

- [`ed companion discrepancies`](./discrepancies.md), the individual divergences behind these numbers
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
