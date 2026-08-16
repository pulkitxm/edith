# Reasoning it does on its own

A system that summarises you well is not the same as one that thinks about you.
This page is the difference: the four mechanisms that let the companion hold
theories, test them, notice when your account of yourself does not match what
happened, and ask you about the holes it cannot fill on its own. Back to
[how the companion works](./concepts.md).

## What you said is not what happened

When you say "I have been on top of things this week", the system has learned
exactly one thing with certainty: that you said it. Whether you were on top of
things is a separate question with separate evidence. Most personal software collapses
those two into one store and becomes an elaborate paraphrase machine, where
everything it "knows" is your self-description with extra steps.

So they are two tables. `claims` holds what you asserted, with the literal hedge
words you used and the type of assertion it was. `observations` holds what
happened: commits, calendar events, file times, app usage, anything a connector
saw without you deciding to record it. That second table is worth more precisely
because you did not author it for the system's benefit.

Every belief then carries how well supported it is:

| Level | Meaning |
| --- | --- |
| `self_reported` | You said it, nothing else touches it. |
| `corroborated` | You said it, and the records agree. |
| `contradicted` | You said it, and the records disagree. |
| `observed_only` | You never said it; the system found it in the record. |

`contradicted` is not an accusation, it is the highest information state in the
system. It usually means something more interesting than dishonesty: that you are
optimistic about progress, or harder on yourself than the record supports, or
that the week you called bad looks statistically ordinary.

## Theories, not just notes

A belief with no prediction attached can never be wrong, so beliefs only ever
accumulate. That is note taking. A **hypothesis** is a belief with a testable
consequence bolted on, and that single addition is what lets the reflection loop
be wrong on its own account and find out.

Every hypothesis must name a **mechanism**, at least **two alternative
explanations** of the same evidence, and a **prediction** with an observable and
a window. When the window closes, the prediction resolves against the record and
the posterior moves: confirmation multiplies the odds by three, denial divides by
three, and the trajectory is kept rather than overwritten, so
[`ed companion why`](./why.md) can print how a theory's confidence actually moved.

Two guardrails hold the ledger honest. Active theories are capped at thirty, and
anything that has not produced a resolvable prediction in ninety days retires
itself. A theory whose only support is your own account of yourself is skipped
at generation: if the system's model of you comes entirely from your description
of you, it has not thought, it has agreed.

## Corroboration, and being wrong in both directions

Standups are the cleanest instance. A transcript comes in, claims come out, each
testable claim gets an observable attached, and later a job resolves it against
what the connectors saw. One data point is noise. Two hundred is a calibration
curve, and that is the useful object: what "almost done" has historically meant
for you, in days.

Calibration is scored in both directions and per domain, because estimating work,
judging yourself and reading risk are different skills:

| Pattern | What the record shows |
| --- | --- |
| Overconfidence | "Nearly done" has meant another week, repeatedly. |
| Underconfidence | You called three things failures; two shipped and one was praised. |
| Miscalibrated worry | You have flagged this risk five times; it happened once. |
| Missed signals | You have mentioned this eleven times and called it minor every time. |

The last two are what make it feel like attention rather than accounting.

Work is invisible to connectors constantly: pairing, design, review, thinking,
another machine, an unpushed branch. So absence of records resolves as unclear,
never as failure, and
[`ed companion discrepancies override`](./discrepancies.md) is the one tap
correction that teaches the aggregate which of your work types the records
systematically cannot see.

## It asks, but only about the biggest hole

The system already knows where it is weak: beliefs it has marked contested,
theories whose predictions cannot resolve without a fact only you have, people it
hears about often and knows thinly. Each becomes a candidate question with an
expected gain, and the highest one is what you get.

`motive` is a required field and it is the whole design. Before a question can be
asked, the system must state internally what it expects to learn and which belief
or theory the answer moves. If it cannot say, the question does not get asked.

The rules that decide whether you keep answering after week two: three a day at
most, never as a notification, one at a time, and it says what your answer
changed. Personal topics unlock as you answer rather than being available on day
one, and anything you mute stays muted.

## Lenses, and what disagreement is for

A persona is not a tone. Six things vary and only the last is the prompt:
retrieval policy, evidence weighting, which passes run, the shape of the answer,
how sure it must be before it speaks, and the voice. Personas share all of memory,
because fragmenting memory per lens would be a serious mistake, but each keeps its
own note about what works when speaking to you, written by the nightly agent and
never by the lens itself mid conversation.

Because the lenses genuinely differ, they can genuinely disagree, and a council
run ends with a synthesis pass whose only job is to find the crux: the specific
unknown the disagreement reduces to. That is more useful than any single confident
answer, and it feeds straight back into the question ledger.

## Where to go next

- [The learning loop](./concepts-learning.md), the nightly run these hook into
- [`ed companion hypotheses`](./hypotheses.md), the theories in practice
- [`ed companion inquire`](./inquire.md), the question ledger in practice
- [How the companion works](./concepts.md), the hub
- [All `ed` commands](../README.md)
