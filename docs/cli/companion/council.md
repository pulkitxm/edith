# `ed companion council`

Asks several lenses the same question in parallel, then runs a synthesis pass whose
only job is to locate the crux: the one fact none of them has, which would settle the
disagreement if it were known. The disagreement is the output. A single confident
answer would tell you less.

Usage:

```
ed companion council "<question>" [--personas analyst,coach,skeptic] [--json]
                                  [--endpoint <url>]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--personas` | comma separated lens ids | `analyst,coach,skeptic` | Which lenses sit on the council. Two is the minimum. |

Each lens answers through its own retrieval policy and evidence weighting, so they
can genuinely disagree rather than paraphrasing one another. The plain output prints
each answer, then where they agree, where they diverge, the crux, and the question
worth answering before you decide.

`--json` shape: `{question, agreement, divergence, crux, cruxQuestion, model,
answers: [{persona, label, answer, abstained, grounding, citations}]}`.

Three model calls is right for a question about changing jobs and absurd for what you
did last Tuesday. Default to [`ed companion ask`](./ask.md) and escalate here.

## Where to go next

- [`ed companion personas`](./personas.md), the lenses and how each thinks
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
