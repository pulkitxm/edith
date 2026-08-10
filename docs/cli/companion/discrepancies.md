# `ed companion discrepancies`

Where your account of your own work and the record of it parted company, and the way
to tell the system when the record was simply not looking.

Usage:

```
ed companion discrepancies [ls] [--limit <n>] [--json] [--endpoint <url>]
ed companion discrepancies override <id> --real "<what actually happened>"
                                    [--json] [--endpoint <url>]
```

Kinds are `overstated`, `understated`, `timing_off` and `invisible_work`. Understated
matters as much as overstated: a system that only ever catches you overclaiming is a
pessimism engine, and just as wrong as a yes-man in the other direction.

The system may state a discrepancy as fact and ask about it. It may not assign a
motive. Motive is exactly the thing it has no evidence for, and where a wrong guess
does real damage.

`ed companion discrepancies ls` (also the bare default) lists the divergences newest
first, each with the claim it came from and whether you have already set it straight.

`ed companion discrepancies override` is the one tap correction for work the
connectors could not see: pairing, design, review, thinking, another machine, an
unpushed branch. It reopens the commitment as met, marks the calibration as a
dismissed signal rather than a miss, and teaches the aggregate which of your work
types are systematically invisible. Without it the aggregates are junk.

`--json` shape for `ls`: an array of `{id, claim, kind, magnitude, detectedAt,
dismissed, userResponse}`.

## Where to go next

- [`ed companion calibration`](./calibration.md), the same evidence read in both directions
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
