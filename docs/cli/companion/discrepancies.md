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
unpushed branch. It changes a linked commitment from `missed` to `met`; commitments
in other states keep that state. It also marks the calibration as a dismissed signal
rather than a miss, stores your text as both the discrepancy response and commitment
override, changes the discrepancy kind to `invisible_work`, and marks it dismissed.

`--json` shape for `ls`: an array of `{id, claim, kind, magnitude, detectedAt,
dismissed, userResponse}`.

`override` requires `--real`. Its JSON shape is `{id, ok}`. An unknown id, an id that
is not a discrepancy, or an empty correction is refused.

`ls --limit` defaults to 20 and must be positive.

## Where to go next

- [`ed companion calibration`](./calibration.md), the same evidence read in both directions
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
