# The learning loop: claims, observations and beliefs

Part of [how the companion works](./concepts.md), under
[`ed companion`](./README.md) in [the CLI reference](../README.md). Chat
reads your memory; this page is about how the companion **thinks about** it:
the nightly pipeline that extracts what you asserted, checks it against
external records, and distills durable beliefs about how you work.

## Why a nightly loop exists

Raw episodes are evidence, not understanding. "I'll finish the billing
migration this week" sitting in a Tuesday note is just text until something
notices it is a commitment, checks whether it happened, and folds the
pattern into a picture of you. That work needs the reasoner (the language
model), which costs time and money per call, so it runs as a batch while you
sleep rather than on every ingest. Each layer it builds is stored with
pointers back to its evidence, so every conclusion can be traced to the
words it came from.

## Claims: what you asserted

A **claim** is one assertion you committed to, kept in your own words, with
a type from a fixed list of eight:

| Type | Example |
| --- | --- |
| `fact` | "The core has been stable since Tuesday." |
| `intention` | "I want to build an offline-first journal." |
| `commitment` | "I'll finish the billing migration this week." |
| `progress` | "Shipped the auth refactor." |
| `self_assessment` | "I'm bad at starting billing work." |
| `prediction` | "The launch will slip a week." |
| `preference` | "Mornings are for deep work." |
| `feeling` | "The Goa trip reset my sleep." |

Each claim also carries a `testable` flag: could independent records, like
commits or a calendar, confirm or refute it? "Shipped the auth refactor" is
testable; "the trip reset my sleep" is not.

Extraction is a bounded batch. Each pass takes the 10 newest episodes that
have no claims yet, shows the reasoner the first 1500 characters of each,
and asks for zero to six claims per episode as structured JSON. Replies are
validated defensively: statements shorter than six characters are dropped,
unknown types are dropped, a missing `testable` defaults to false. The
claim's `asserted_at` is the **episode's** date, not extraction night,
because what matters is when you said it.

Claims are insert-only. Restating an intention next week creates a sibling
claim, not an update; the only guard against duplication is that each
episode is processed once. Convergence happens one layer up, at beliefs.

## Observations: what the world recorded

An **observation** is an externally recorded event, and it obeys one hard
provenance rule: observations never come from anything you wrote for the
companion. You can tell it you shipped; only the record can show it. That
separation is the entire point, because it gives corroboration something you
cannot accidentally, or conveniently, author yourself.

GitHub live sync pulls up to 300 recent authenticated-user events and keeps
four kinds:

| Kind | From | Dedupe key |
| --- | --- | --- |
| `commit` | Push events, one per commit | `github:commit:<sha>` |
| `pull_request` | PR opened, closed, merged | repo, number, action, merged |
| `issue` | Issue opened, closed | repo, number, action |
| `review` | PR reviews | review id |

Every observation carries a dedupe key with a uniqueness rule behind it, so
syncing is idempotent: running it twice never double-counts a commit. The
same shape also holds imported calendar meetings, reschedules, music plays and
video watches, plus Edith usage records. Notion live sync follows a different
path: it renders pages as Markdown and ingests them as episodes because a page
is authored memory, not independent behavioral evidence.

## Corroboration: claims meet reality

Corroboration is a judged comparison between what you said and what was
recorded. Each pass picks up to 10 unchecked claims that are testable and of
a checkable type (`progress`, `commitment` or `fact`), and for each one
gathers up to 40 observations from a window of 96 hours either side of the
claim's assertion time: four days of surrounding reality.

The reasoner is shown the claim and those observations and must return one
verdict with a short note:

- `corroborated`: the records support it.
- `contradicted`: the records conflict with it.
- `unclear`: the records do not settle it.

One asymmetry is built in deliberately: **absence of records always reads as
`unclear`, never as `contradicted`.** No commits around "I shipped it" might
mean you did not ship, or that the work lives in a private repo the
connector cannot see. The companion refuses to convict on missing evidence;
a malformed or overconfident model reply is also coerced to `unclear`. The
verdict, note and the exact observation ids the judge saw are stored, so
every verdict is auditable. `ed companion claims` shows each claim wearing
its latest verdict.

## Beliefs: durable conclusions with a life-cycle

A **belief** is a higher-order statement about how you work, feel or decide,
explicitly not a restatement of a single note: "deep work happens on morning
walks" rather than "went for a walk Tuesday". Each has a kind (`pattern`,
`preference` or `state`), a confidence between 0 and 1, and the episode ids
it rests on.

Reflection (nightly, or `ed companion reflect`) shows the reasoner the 20
newest episodes, 1200 characters each, and asks for two to five beliefs as
JSON. Validation is strict: statements must be over ten characters,
confidence is clamped into range, and cited evidence must be among the 20
episodes actually shown; a belief with no surviving evidence is dropped.
The same grounding discipline as chat citations, applied to conclusions.

New candidates then meet the existing stock, and this is where the embedding
machinery from [chunks, embeddings and search](./concepts-search.md) returns:
every belief is embedded, and each candidate is compared by cosine
similarity against active beliefs.

| Similarity to nearest active belief | What happens |
| --- | --- |
| 0.90 or above | Same belief again: the old one is **strengthened** (stability rises by one, last-confirmed updates, evidence lists merge) |
| 0.80 up to 0.90 | A revision: the new belief is inserted and the old one is marked **superseded**, linked to its replacement |
| below 0.80 | Genuinely new: a fresh belief is formed |

So repetition builds stability, drift produces an auditable chain of
revisions, and novelty grows the set. Beliefs are never deleted; the Mind
tab shows superseded ones dimmed, a visible history of the companion
changing its mind.

## The nightly run itself

A scheduler starts with the server and fires once a day at
`COMPANION_REFLECT_AT`, default 02:00 in the server's local timezone (a
seconds-based interval override exists for testing, and the schedule is read
once at boot, so changing it needs a restart). The steps run in dependency
order: sync GitHub, sync Notion, index, rescore baselines, extract claims,
resolve entities, extract temporal facts, corroborate, track commitments,
score calibration, reflect, resolve due predictions, form hypotheses, rewrite
core memory, rewrite lens notes and rank questions.

Missing connector tokens record successful skipped sync steps. A missing
reasoner records a successful `reasoning` skip after baselines and ends the run
there, so a partly configured companion still syncs and indexes every night.
Other failures are recorded per step and make the overall run unsuccessful,
while later independent steps still get a chance to run. Each run stores its
start, finish, overall result and per-step outcomes in `nightly_runs`;
`ed companion runs` lists them and the Mind tab renders the latest run as
step chips. `ed companion nightly` runs the identical pipeline on demand and
waits for it.

Because extraction and reflection work in bounded batches (10 and 20
episodes), a large backlog is digested over successive nights rather than in
one giant, failure-prone pass: the design assumes a steady trickle of new
memory, which is how the companion "keeps adding stuff" without ever
reprocessing everything.

## Reading on

- [Memory](./concepts-memory.md): the ladder these layers live in.
- [Asking and chatting](./concepts-chat.md): the fast read path that sits on
  top of everything the nightly loop maintains.
