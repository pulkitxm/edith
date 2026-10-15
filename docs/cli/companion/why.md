# `ed companion why`

Prints the whole chain behind anything the companion believes: the evidence episodes,
what argues against it, the prompt version that produced it, how its confidence
moved, and how it was checked against the record. When the system says something
about you that feels wrong, this is how you find out whether it is wrong or you are.

Usage:

```
ed companion why <id> [--json] [--endpoint <url>]
```

The id can name a belief, a hypothesis or a claim, and the output follows what it
found:

- a **belief** prints confidence, stability, corroboration, the episodes it rests on
  and the episodes that argue against it
- a **hypothesis** prints its mechanism, alternatives and recorded posterior
  revisions; the current CLI does not include its predictions
- a **claim** prints when you said it and every verdict the record returned

No claim is allowed to bottom out at "the system concluded this". Every chain runs
down to something you actually said or something a connector actually saw.

`--json` shape: `{kind, id, statement, status, confidence, stability, corroboration,
promptVersion, mechanism, prior, posterior, alternatives, evidence, counterEvidence,
episode, revisions, verdicts}`, with the fields that do not apply left null.
The top-level confidence, stability, prior and posterior values are formatted as
four-decimal strings when present; revision posteriors remain JSON numbers.
Fields that do not apply are null for scalar values and empty arrays for list values.
The API has additional belief links and dates, hypothesis test and prediction data,
and claim metadata that the current CLI client does not expose.

## Where to go next

- [`ed companion beliefs`](./beliefs.md), what it currently holds
- [`ed companion hypotheses`](./hypotheses.md), the theories it can be wrong about
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
