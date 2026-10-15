# `ed companion hypotheses`

The theories the companion holds about you, and how they are faring. A belief with no
prediction attached can never be wrong, so beliefs only ever accumulate; that is note
taking, not thinking. A hypothesis is a belief with a testable consequence bolted on,
which is what lets the system be wrong on its own account and find out.

Usage:

```
ed companion hypotheses [ls] [--limit <n>] [--json] [--endpoint <url>]
ed companion hypotheses run [--json] [--endpoint <url>]
```

`ed companion hypotheses ls` (also the bare default) lists each theory with its
status, its current posterior, the mechanism it rests on and how many times it has
been tested. `--json` shape: an array of `{id, statement, mechanism, status, prior,
posterior, testCount, alternatives, formedAt, generatedBy}`.

Status moves on evidence: `proposed`, `testing`, `supported`, `weakened`, `refuted`
or `retired`. After a scored test, posterior at least 0.8 becomes `supported` only
from the second test, at most 0.2 becomes `refuted`, below 0.4 becomes `weakened`,
and the rest stays `testing`. An unresolvable prediction writes a testing revision
but does not change the hypothesis row's posterior, test count or status.

Two rules are enforced rather than encouraged. Every generated theory must name a
mechanism, at least two alternative explanations and one prediction whose window is
clamped to 3 through 90 days. A `proposed` or `testing` theory older than 90 days is
retired only when none of its predictions has resolved. Generation is skipped when
30 proposed or testing theories exist at the start of a run; because one run can
form several theories, the stored count can briefly exceed 30.

`ed companion hypotheses run` resolves any predictions whose window has closed, moves
the posteriors, then forms new theories from what the record now shows. The nightly
run does both in that order, after scoring discrepancies in the same pass. It
requires a reasoning provider, mutates without confirmation and can leave earlier
resolutions committed if a later operation fails. JSON output is `{ok: true}`.

`ls --limit` defaults to 20 and must be positive.

## Where to go next

- [`ed companion predictions`](./predictions.md), what each theory expects to happen
- [`ed companion why`](./why.md), the whole chain behind one of them
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
