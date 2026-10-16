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
disposition. The available persona pipelines use these checks selectively:

| Pass | What it does |
| --- | --- |
| Question reframing | Restates what you asserted as a neutral question and answers that, then renders it conversationally. Questions draw far less agreement than statements, and agreement rises with how certain you sound. |
| Counterfactual | Before answering, states what the answer would be if the opposite premise held. A check against agreeing by reflex, not an answer. |
| Announced scoring | The answer is scored: right claims gain, unsupported claims lose, and saying plainly that there is not enough to judge gains a little. Abstention is a legitimate move rather than a failure. |

That last one is tuned deliberately. Over-penalising a wrong answer buys accuracy by
producing a system that shrugs, so refusing to engage with something it does have
evidence for is scored as its own failure in the eval suite.

The shipped analyst, coach and skeptic reframe questions. Analyst and skeptic also
run the counterfactual pass. Friend runs neither, while every shipped lens performs
the grounding check and can revise.

## Grounding, and the critic that cannot see your face

Every citation carries typed support: `verbatim`, `paraphrase` or `inference`, and
the type is checked rather than trusted. A quote claimed as
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
critique, and the answer is written again. Grounding uses the configured remote
scorer when it is available and falls back to lexical overlap when it is not.

Length is a signal too: response length correlates strongly with unsupported
content, so every lens carries a word cap and a long answer is flagged for the extra
pass.

## Having opinions on purpose

Suppressing agreement alone produces a hedge machine, not a friend. Opinions need
their own mechanism, and their authority comes from one place: the system has seen
the pattern before. "I would push back on that, you described the last two projects
the same way a fortnight before dropping them" has standing. "I think you should
take the job" is a stranger's guess.

The current opinion pass is looser than that ideal. It selects the retrieved belief
with the largest stability-times-confidence score among beliefs with stability at
least 2 and confidence at least 0.6. It does not independently verify tension or
require the returned opinion to cite an episode. The prompt tells it to lead with an
observation and avoid assigning motive, and any result longer than 20 characters is
accepted.

## Measuring it

The eval suite is how a prompt change is judged rather than felt. Its eight cases
across six families cover being
clearly in the wrong while framed sympathetically, the same false claim at three
levels of your certainty, a claim your own history contradicts, a question about
something that never happened, real new evidence that should change its mind, and
the first case framed as turn sixty after implied rapport.

The distinction that matters in the results: changing your mind and ending up more
correct is being persuadable and you want it. Changing your mind and ending up wrong
is the failure. Cases run independently; the long-session condition is prompt text,
not a persisted conversation.

## Where to go next

- [`ed companion eval`](./eval.md), running the suite
- [`ed companion personas`](./personas.md), the lenses these passes belong to
- [Asking and chatting](./concepts-chat.md), the pipeline they sit inside
- [How the companion works](./concepts.md), the hub
- [All `ed` commands](../README.md)
