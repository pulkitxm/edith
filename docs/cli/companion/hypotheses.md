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

Status moves on evidence: `proposed` until a prediction resolves, then `testing`,
then `supported`, `weakened` or `refuted`. A refuted theory is as much a success as a
confirmed one, and if nothing is ever refuted the generator is too timid.

Two rules are enforced rather than encouraged. Every theory must name a mechanism and
at least two alternative explanations, and one that cannot be tested within ninety
days retires itself, so the ledger cannot fill with unfalsifiable folk psychology.
Active theories are capped at thirty.

`ed companion hypotheses run` resolves any predictions whose window has closed, moves
the posteriors, then forms new theories from what the record now shows. The nightly
run does both in that order, because generation should see yesterday's discrepancies.

## Where to go next

- [`ed companion predictions`](./predictions.md), what each theory expects to happen
- [`ed companion why`](./why.md), the whole chain behind one of them
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
