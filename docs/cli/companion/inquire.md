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
asking right now, or nothing at all once the day's budget of three is used. `--explain`
prints the motive: what it expects to learn and which belief or theory the answer
moves. A question that cannot state that does not get asked, and that is the whole
design.

`ed companion inquire answer` stores your answer as an ordinary episode and says what
it changed, because answering into a void twice is how people stop answering.

`ed companion inquire skip` records the pass. Skip a topic three times and questions
on it are suppressed. `ed companion inquire mute` is the permanent version, and the
onboarding interview asks for that list up front.

Personal questions are gated: sensitivity rises to personal after four answers and to
money, health and relationships after twelve. They are the high value questions and
the ones that land badly if the system has not earned them.

`--json` shape for `ls`: `{askedToday, dailyBudget, muted, questions: [{id, question,
motive, topic, status, expectedGain, resolution}]}`.

## Where to go next

- [`ed companion beliefs`](./beliefs.md), the contested ones these questions target
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
