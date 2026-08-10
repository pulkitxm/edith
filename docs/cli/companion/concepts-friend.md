# Not being a yes-man

Two properties make this system worth having and are also, together, the thing to
manage: it knows you deeply, and it is warm. Either alone is harmless. Combined and
unmanaged they compound into agreement without reality testing. So the passes below
are not polish, they are load bearing. Back to
[how the companion works](./concepts.md).

## Why "don't be sycophantic" does nothing

Sycophancy is not a prompt layer bug. Human labellers prefer agreement, that tilts
the learned reward, and optimisation amplifies whatever correlates with reward. That
fix lives upstream of anyone consuming an API. Measured, an explicit instruction to
be honest is the weakest of the available interventions and sometimes backfires.

What measurably works is specifying a **decision procedure** rather than a desired
disposition, and three of them run in the pipeline:

| Pass | What it does |
| --- | --- |
| Question reframing | Restates what you asserted as a neutral question and answers that, then renders it conversationally. Questions draw far less agreement than statements, and agreement rises with how certain you sound. |
| Counterfactual | Before answering, states what the answer would be if the opposite premise held. A check against agreeing by reflex, not an answer. |
| Announced scoring | The answer is scored: right claims gain, unsupported claims lose, and saying plainly that there is not enough to judge gains a little. Abstention is a legitimate move rather than a failure. |

That last one is tuned deliberately. Over-penalising a wrong answer buys accuracy by
producing a system that shrugs, so refusing to engage with something it does have
evidence for is scored as its own failure in the eval suite.

## Grounding, and the critic that cannot see your face

Every claim carries typed provenance: `verbatim`, `paraphrase`, `inference` or
`unsupported`, and the type is checked rather than trusted. A quote claimed as
verbatim that does not actually appear in the source is downgraded to paraphrase
before it ever reaches you, and the app renders the tiers differently, because an
inference presented with the visual weight of a quote is the most dangerous mistake
available here.

Then the answer is scored for groundedness against the evidence it was given, and
the score is stored on the turn. When it is low, or sentences cannot be tied to the
evidence, a critic pass runs with a different prompt **and different context**: it
sees the evidence and the draft, but not how you framed the question. It has no face
in front of it to preserve, which structurally removes the pressure that produces
validation. Its complaints, plus the specific unsupported spans, go back as the
critique, and the answer is written again. The outside signal is what makes the loop
non-circular; bare self-critique mostly does not help.

Length is a signal too: response length correlates strongly with unsupported
content, so every lens carries a word cap and a long answer is flagged for the extra
pass.

## Having opinions on purpose

Suppressing agreement alone produces a hedge machine, not a friend. Opinions need
their own mechanism, and their authority comes from one place: the system has seen
the pattern before. "I would push back on that, you described the last two projects
the same way a fortnight before dropping them" has standing. "I think you should
take the job" is a stranger's guess.

So the opinion pass is separate, fires only when a high stability belief tensions
with what you just said, and requires the belief and its evidence episodes as
inputs. If it cannot cite, it does not fire. It leads with the observation rather
than the verdict, and it never assigns a motive.

## Measuring it

The eval suite is how a prompt change is judged rather than felt. It covers being
clearly in the wrong while framed sympathetically, the same false claim at three
levels of your certainty, a claim your own history contradicts, a question about
something that never happened, real new evidence that should change its mind, and
the first case again at turn sixty after rapport has built.

The distinction that matters in the results: changing your mind and ending up more
correct is being persuadable and you want it. Changing your mind and ending up wrong
is the failure. Once a model caves in a conversation it tends to stay caved, so the
suite measures per session rather than per turn.

## Where to go next

- [`ed companion eval`](./eval.md), running the suite
- [`ed companion personas`](./personas.md), the lenses these passes belong to
- [Asking and chatting](./concepts-chat.md), the pipeline they sit inside
- [How the companion works](./concepts.md), the hub
- [All `ed` commands](../README.md)
