# `ed companion inquire`

The questions the companion wants to ask you, ranked by the size of the hole they
would fill rather than picked at random.

Usage:

```
ed companion inquire [next] [--explain] [--json] [--endpoint <url>]
ed companion inquire answer <id> "<your answer>" [--json] [--endpoint <url>]
ed companion inquire skip <id> [--json] [--endpoint <url>]
ed companion inquire mute <topic> [--json] [--endpoint <url>]
ed companion inquire ls [--limit <n>] [--json] [--endpoint <url>]
```

`ed companion inquire next` (also the bare default) returns the single question worth
asking right now, or nothing when the day's budget of three is used or no pending
question passes the sensitivity and mute filters. `--explain`
prints the motive: what it expects to learn and which belief or theory the answer
moves. A question that cannot state that does not get asked, and that is the whole
design.

`next` is not a read-only peek. On first use it seeds the six onboarding questions,
marks the returned question as asked, and consumes one of the three daily slots.

`ed companion inquire answer` stores your answer as an ordinary episode and marks the
question answered. A targeted contested belief is marked active regardless of the
answer text; the returned resolution says which target category was touched.

`ed companion inquire skip` records the pass. During question ranking, three skipped
questions on the same topic suppress other queued questions on that topic.
`ed companion inquire mute` is the permanent CLI version, and the onboarding
interview asks for that list up front. It normalizes the topic and suppresses
currently pending matches; there is no CLI unmute command.

Personal questions are gated: sensitivity rises to personal after four answers and to
money, health and relationships after twelve. They are the high value questions and
the ones that land badly if the system has not earned them.

`--json` shape for `ls`: `{askedToday, dailyBudget, muted, questions: [{id, question,
motive, topic, status, expectedGain, resolution}]}`.

The other JSON shapes are:

- `next`: `{id, question, motive, topic, expectedGain, sensitivity}`, or
  `{question: null}` when nothing is available
- `answer`: `{question, episodeId, resolution, askedToday}`
- `skip`: `{id, status}`, where `status` is `skipped`
- `mute`: `{topic, suppressed}`

`--explain` affects plain output only. `ls --limit` defaults to 20 and must be
positive. Answering or skipping an unknown question is refused.

## Where to go next

- [`ed companion beliefs`](./beliefs.md), the contested ones these questions target
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
