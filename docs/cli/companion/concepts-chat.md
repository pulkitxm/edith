# Asking and chatting: how memory becomes answers

Part of [how the companion works](./concepts.md), under
[`ed companion`](./README.md) in [the CLI reference](../README.md). This page
explains what happens between your question and the companion's reply: how
memories are selected, how the language model is briefed, how the reply
streams in, and how citations are checked so the answer cannot quietly make
things up.

## The reasoner has no memory of you

The language model behind chat, called the **reasoner**, is a general text
model: Claude through the Anthropic API, or a local model like `qwen3:1.7b`
through Ollama. It was trained long before it met you, knows nothing about
your notes, and retains nothing between requests. Every single question is
answered by a model that starts blank and is handed a briefing.

This pattern is called retrieval-augmented generation, and it is the second
half of the mental model from [memory](./concepts-memory.md): storage is
dumb and permanent, intelligence is rented and momentary. The quality of an
answer therefore depends on two independent things: whether retrieval picked
the right memories, and whether the reasoner used them well. When an answer
is bad, it is worth asking which half failed.

## Step one: pick the memories

Your message is embedded with the same model that embedded every chunk (see
[chunks, embeddings and search](./concepts-search.md)), and the 8 nearest
chunks by meaning are fetched. Always exactly 8, for ask and chat alike: no
more for hard questions, no fewer for easy ones. Claims, beliefs and
observations are **not** retrieved; answers are grounded in your own words,
not in the companion's derived conclusions.

If the memory is completely empty, chat is briefed with a literal note that
the memory is empty, and ask returns a canned "there is nothing in the
memory yet to answer from".

## Step two: brief the reasoner

The briefing (the "prompt") has a fixed shape. Each chunk is rendered with
its provenance:

```
episode 3f7f7a68-... (2026-03-14) Warden retro
Shipped the auth refactor this week. Felt slower than it should have been.
```

All 8 render into one "Excerpts" block. The episode ids are the load-bearing
part: they are how the model can say **which memory** an answer rests on,
and how the server later checks it. There is no token budgeting; 8 chunks of
at most 1600 characters is the built-in ceiling, roughly 13k characters of
memory per question.

Chat adds two more things. A short standing instruction (the "system
prompt") tells the model who it is: a thoughtful confidant who knows one
person through their own notes, voice memos and records, replying in plain
prose. And the last 12 messages of the current conversation are included, so
"what about the week before?" makes sense as a follow-up. Older messages
simply fall off; there is no summarising of long conversations yet.

## Step three: ask versus chat

The two endpoints brief the same way but answer differently.

**Ask** (`ed companion ask`, `POST /v1/ask`) is one-shot and strict: the
model must reply with pure JSON, an `answer` string plus a `citations`
array, nothing else. No history, no persona, no streaming. It is the
scriptable form: one question in, one structured document out.

**Chat** (`ed companion chat`, `POST /v1/chat`) is conversational and
streams. The model writes its reply as natural prose and then, on its own
line, a marker `@@CITATIONS@@` followed by the citations as JSON. You watch
the prose arrive word by word; the marker and everything after it never
reach your screen, because the server captures that tail and processes it as
data.

Streaming uses server-sent events, a plain HTTP response that stays open
while the server writes small events down it. One chat reply is the sequence
`meta` (conversation id and model), many `delta` events (each a few more
characters of prose), one `citations` event (the validated array), and
`done` (message id, latency, chunks considered), with `error` replacing the
tail if something breaks.

## The stream filter

Between the model and your screen sits a small state machine with two jobs:

- **Strip thinking.** Local models often emit their private reasoning inside
  `<think>...</think>` tags before the real answer. Everything inside is
  dropped; if a model opens the tag and never closes it, the rest of the
  reply is dropped too rather than leaking half-finished reasoning.
- **Divert citations.** From `@@CITATIONS@@` onward, output goes into a
  buffer for validation instead of the visible stream.

The subtle part is that a streamed reply arrives cut at arbitrary points, so
a marker can be split across two events (`@@CITA` then `TIONS@@`). The
filter holds back any suffix of the visible text that could be the start of
either marker until enough has arrived to decide, so you never see a
stray fragment of `<think>` or `@@CIT` flash by mid-sentence.

## Step four: police the citations

A citation is the model saying "this part of my answer rests on that
episode, and here is the quote". Models are eager to please and will cite
confidently even when wrong, so the server verifies every citation
mechanically before you see it. Two rules:

**Grounding.** A citation must name one of the 8 episodes the model was
actually shown. Any other id, plausible or not, is silently dropped. An
answer can only cite what it read; it cannot launder invented sources into
the record.

**Support grading.** Each citation carries a `support` level, and the server
re-grades it by checking the quote against the cited chunk's real text,
compared with whitespace squashed and case folded so cosmetic differences do
not matter:

| Model claimed | Quote found in the text? | Final label |
| --- | --- | --- |
| `verbatim` | yes | `verbatim` |
| `verbatim` | no | demoted to `paraphrase` |
| `paraphrase` | yes | upgraded to `verbatim` |
| `paraphrase` | no | `paraphrase` |
| `inference` | not checked | `inference` |

So `verbatim` on screen is a structural guarantee, not the model's opinion:
that exact quote exists in that exact episode. `paraphrase` means the idea
is there in other words. `inference`, which the CLI renders as "reading
between the lines", flags the model connecting dots, the right label for
"you kept avoiding the billing work" when no note says those words.

## Step five: what gets kept

After the reply finishes, chat writes both sides into the `conversations`
and `messages` tables: your message, the assistant's text, its validated
citations, which model answered, and the latency. Conversation titles are
cut from the first message, at most 60 characters, preferring a word
boundary. History survives restarts, `ed companion conversations` replays
it, and `ed companion forget` deletes a conversation with its messages.

Separately, every search, ask and chat logs telemetry: a `turns` row for
the query, model and latency, plus one `retrievals` row per retrieved chunk
recording its rank and whether it ended up cited. That "was this retrieved
chunk actually useful?" trail is the raw material for evaluating and tuning
retrieval later.

Two deliberate absences complete the picture. The companion's replies are
never ingested back as memory, so it learns only from you, never from
itself; a wrong answer cannot become tomorrow's evidence. And ask writes
nothing at all: it is a pure read.

## Reading on

- [Chunks, embeddings and search](./concepts-search.md): how the 8 chunks
  are chosen in the first place.
- [The learning loop](./concepts-learning.md): the slower path where the
  reasoner works on your memory overnight.
