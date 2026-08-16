# Memory: what the companion actually stores

Part of [how the companion works](./concepts.md), under
[`ed companion`](./README.md) in [the CLI reference](../README.md). This page
explains what "memory" means here, where every byte lives, and why the design
is append-only. No machine-learning background is assumed.

## Memory is a database, not a brain

When the companion "remembers" something, no model is being trained and
nothing is being memorised by an AI. Memory is ordinary data in an ordinary
database: rows in Postgres and files on disk. The intelligence only shows up
later, at read time, when a language model is handed a small selection of
those rows and asked to answer with them. This is the single most useful
mental model for the whole system: **storage is dumb and permanent,
intelligence is rented and momentary.**

That split has practical consequences:

- You can inspect everything. Every remembered fact is a row you can query
  and a file you can open. Nothing is hidden inside model weights.
- Deleting or exporting memory is a database operation, not a retraining:
  `ed companion export`, `import`, `erase` and `wipe` are those operations.
- Swapping the language model (the "reasoner") changes how well the companion
  talks about your memory, but never changes the memory itself.

## The ladder: five kinds of record

Memory is organised as a ladder. Each rung is derived from the one below it,
and each rung adds a layer of interpretation:

| Rung | Table | What it is | Made by |
| --- | --- | --- | --- |
| 1 | `sources` | A unique file you gave it, identified by fingerprint | Ingestion |
| 2 | `episodes` | One memory event: the readable body of that file, with a time | Ingestion |
| 3 | `chunks` | Small searchable pieces of an episode, each with an embedding | Indexing |
| 4 | `claims`, `observations` | Things you asserted, and things the world recorded | The nightly loop |
| 5 | `beliefs` | Durable conclusions about how you work | Reflection |

Walk one note up the ladder. Say you drop `goa-trip.md` containing a journal
entry. Ingestion fingerprints the text, stores the original file, and creates
one `sources` row and one `episodes` row (rungs 1 and 2). Indexing splits the
body into a few `chunks` and computes an embedding for each (rung 3), which
is what makes the note findable when you later ask "what did I want to build
after Goa?". That night, the claim extractor may pull out "I want to build an
offline-first journal" as a `claims` row (rung 4). After a few similar notes,
reflection may form the `beliefs` row "wants long unstructured mornings
before screen time" (rung 5). The original words are never altered by any of
this; higher rungs only ever point back down with ids.

Chat and ask answer from rung 3. The Mind tab and `ed companion beliefs`,
`claims` and `observations` show rungs 4 and 5.

## Sources versus episodes

The two bottom rungs look similar but answer different questions.

A **source** answers "have I seen this exact content before?". It stores the
content fingerprint (a SHA-256 hash, explained below), the path of the
preserved original in the vault, and the byte count. The fingerprint column
is unique, which is the whole deduplication mechanism.

An **episode** answers "what happened, and when?". It stores the readable
text (`body_original`), the kind (`md`, `pdf` or `voice`), a title, the
language, and two timestamps: `occurred_at`, when the content happened in
your life, and `ingested_at`, when the companion received it. Search,
chunking, claims and reflection all operate on episodes; they never go back
to the raw file.

Today the relationship is one-to-one, but keeping them separate means one
source could later produce several episodes (say, one per journal heading)
without changing the model.

## Append-only, on purpose

Nothing in memory is ever edited in place:

- Episodes are immutable. There is no update endpoint and no update SQL.
- If you edit a note on disk and drop it again, its text hashes differently,
  so it becomes a brand-new source and episode. The old version stays.
- Beliefs are never deleted by the companion itself. When it changes its mind,
  the old belief is marked `superseded` and linked to its replacement, so you
  can see what it used to think and when.
- Conversations can be deleted (`ed companion forget`), because chat history
  is your convenience data, not the memory of record.

Append-only is a rule for the companion, not a cage for you. The memory is
yours, so deletion is always yours to order: `ed companion erase` removes one
episode and everything derived from it, and `ed companion wipe` empties the
whole store. `ed companion export` writes everything into a bundle that
`ed companion import` restores, so leaving, backing up, or moving machines
never needs database surgery.

Why build it this way? Because the companion's job is to remember what you
wrote **then**, not what you later wished you had written. A diary you can
silently rewrite is not evidence of anything. Append-only also makes the
engineering safer: immutable rows cannot be corrupted by a half-finished
update, and "has this episode been indexed?" has a trivially correct answer
(does it have chunks yet?) precisely because episode bodies never change.

## The fingerprint: SHA-256 in one paragraph

A hash function takes any input, a byte or a gigabyte, and produces a short
fixed-size number, here 256 bits written as 64 hex characters. The same input
always produces the same output, and any change to the input, even one
character, produces a completely different output. Finding two different
inputs with the same output is computationally out of reach, so in practice
the hash is a unique fingerprint of the content. The companion hashes the
text of Markdown files and the raw bytes of PDF and audio files, and treats
"same fingerprint" as "same memory".

## The vault: originals, kept forever

Beside the database sits the vault, a plain directory that keeps the exact
original bytes of everything ever ingested. Its layout is derived from the
fingerprint, a scheme called content-addressed storage:

```
/vault/objects/<first two hex chars>/<full sha256>/<original filename>
```

The two-character prefix just spreads files across subdirectories so no
single directory grows huge. Because the path is the fingerprint, writing is
naturally idempotent: if the path already exists, the content is already
there, byte for byte, and the write is skipped. Nothing in the vault is ever
overwritten or deleted.

The vault matters for two reasons. First, honesty: the episode body for a PDF
or a voice memo is an extraction or a transcription, in other words a lossy
copy, and the vault keeps the ground truth it came from. Second, playback:
`GET /v1/episodes/{id}/media` streams the vault file back out, which is how
the app shows a real PDF page and plays your actual recording rather than
just its transcript.

## Where every byte physically lives

The backend runs as five containers, and all state sits in named volumes on
that machine:

| What | Where | Volume |
| --- | --- | --- |
| Every table (episodes, chunks, beliefs, ...) | Postgres 18 with the pgvector extension | `companion-pg` |
| Original files | The vault directory | `companion-vault` |
| The embedding model | Ollama's model cache | `companion-ollama` |
| The speech-to-text model | whisper.cpp's model dir | `companion-whisper` |

On your Mac the companion stores exactly one thing: the endpoint URL, in the
shared defaults suite. No notes, no keys, no memory. The API key for the
reasoner lives in the `settings` table on the backend, and the server only
ever returns its last four characters as a hint.

Two footnotes about the container stack. Redis is present and health-checked
but nothing uses it yet; it is capacity for future queues, not a load-bearing
part. And there is no SQLite and no scattering of state across files: one
server owns all of it, which is what lets the app, the CLI and remote
machines all see the same memory through one HTTP API.

## What Postgres and pgvector are, briefly

Postgres is a battle-tested relational database: data lives in tables with
typed columns, and you query it with SQL. pgvector is an extension that adds
a vector column type, so a row can carry a list of numbers (an embedding,
explained properly in [chunks, embeddings and search](./concepts-search.md))
and be queried by "which rows are nearest to this vector?". Using one
database for both ordinary rows and vector search keeps every memory
operation transactional: an episode and its chunks either all commit or none
do.

## Reading on

- [Ingestion](./concepts-ingestion.md): the exact path from a dropped file to
  an episode, for all three media.
- [Chunks, embeddings and search](./concepts-search.md): how text becomes
  numbers and how nearest-neighbour search works.
- [Asking and chatting](./concepts-chat.md): how memory turns into grounded
  answers with citations.
- [The learning loop](./concepts-learning.md): claims, observations,
  corroboration and beliefs.
