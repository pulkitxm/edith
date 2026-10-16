# How the companion works

[`ed companion`](./README.md) documents the commands; this page is the
machinery behind them, one line per concept. Back to
[the CLI reference](../README.md).

Each area also has a deep page written for readers with no ML background,
with worked examples and every term explained from scratch:

| Page | What it explains |
| --- | --- |
| [Memory](./concepts-memory.md) | The data ladder, the vault, content hashing, append-only design, where every byte lives |
| [Ingestion](./concepts-ingestion.md) | Dropped file to episode: dedupe, dates, PDF extraction, speech transcription, vision captions and signals |
| [Chunks, embeddings and search](./concepts-search.md) | How text becomes numbers and how nearest-neighbour search finds meaning, from first principles |
| [Asking and chatting](./concepts-chat.md) | Retrieval, prompting, streaming, the stream filter, and how citations are policed |
| [The learning loop](./concepts-learning.md) | Claims, observations, corroboration verdicts, belief life-cycles and the nightly run |
| [Reasoning it does on its own](./concepts-brain.md) | Claims against observations, falsifiable theories, calibration in both directions, and the question ledger |
| [Not being a yes-man](./concepts-friend.md) | Question reframing, counterfactuals, the blind critic, typed provenance and how opinions earn their standing |

Two pipelines carry everything:

- Every file: Markdown, PDF, voice, image or video → SHA-256 dedupe → vault → episode → chunks →
  embeddings → searchable.
- Every night at 02:00: sync GitHub and Notion → index → rescore baselines → extract claims →
  resolve entities → corroborate → track commitments → score calibration → reflect
  into beliefs → resolve predictions → form theories → rewrite the standing summary
  → rewrite the lens notes → rank the questions worth asking.

## The machine

- One Rust server on port 4820; Postgres with pgvector holds every table,
  Ollama embeds, whisper.cpp transcribes, Redis is only pinged. No SQLite.
- The reasoner is a swappable language-model client. An OpenAI-compatible URL
  can run a local model such as `qwen3:1.7b`; settings hot-swap it with no restart.
- The data ladder: `sources` → `episodes` → `chunks` → `claims` and
  `observations` → `beliefs`. Each rung adds interpretation.

## Remembering

- The vault stores original bytes content-addressed by hash; identity is
  SHA-256, so re-dropping a file is a `duplicate`, and editing one creates a
  new episode. Memory is append-only, nothing is updated in place.
- An episode's time prefers front-matter date, then file mtime, then now.
- Chunks are paragraphs packed to at most 1600 chars, zero overlap.
- Embeddings: `qwen3-embedding:0.6b`, truncated to 512 dims (Matryoshka),
  stored as `halfvec` under an HNSW cosine index. Beliefs get one too.
- No file watcher: "needs indexing" simply means an episode with zero chunks.
- Voice and video also yield signals: pauses, words per minute, speech ratio.
- Photos become vision captions with capture metadata. Videos combine speech
  transcripts with timestamped captions of scene-change keyframes.

## Recalling

- Retrieval fuses up to 50 candidates each from vector similarity and keyword
  search, plus entity-graph candidates. Reciprocal-rank fusion is adjusted by
  salience and recency, then an optional reranker can reorder the final pool.
- The answer context can include retrieved chunks, matching active beliefs and
  independent observations. A persona can narrow source kinds or time windows.
- Ask is one-shot JSON; chat streams SSE with the last 12 messages of
  history, prose first, then a `@@CITATIONS@@` trailer the server strips.
- A stream filter drops `<think>` blocks and half-streamed markers.
- Citations are policed: an episode the reasoner was not shown is dropped,
  and `verbatim` is verified structurally or demoted to `paraphrase`.
- Every turn logs retrieval telemetry; replies are never re-ingested, so the
  companion learns only from you, not from itself.

## Thinking

- Claims: assertions extracted from your episodes, typed (fact, intention,
  commitment, progress, and so on) with a `testable` flag.
- Observations: independent records from GitHub, imported calendars, music and
  video history, plus Edith usage, deduped by key. Notion stays on the authored
  side and becomes episodes instead. Observations exist so corroboration can
  check against records you did not write as companion memory.
- Corroboration judges testable claims against observations within 96 hours
  either side; no records means `unclear`, never `contradicted`.
- Reflection distills beliefs from recent episodes; embedding similarity
  drives their life-cycle: 0.90 strengthens, 0.80 supersedes, else new.
  Beliefs are never deleted, only superseded.
- The nightly run records each connector, indexing and learning step at 02:00.
  Missing connector tokens are logged as skipped. Without a reasoning provider,
  it stops after sync, index and baselines; `ed companion runs` shows the log.

## The numbers

| Knob | Value |
| --- | --- |
| Chunk size | 1600 chars, 0 overlap |
| Embedding dims | 512, HNSW cosine |
| Retrieval k | 8 |
| Retrieval candidates | 50 per vector and keyword channel, 25 graph |
| Chat history | 12 messages |
| Claim extraction | 10 episodes, 1500 chars each |
| Corroboration | 96 h window, 40 observations max |
| Reflection | 20 episodes, 2 to 5 beliefs |
| Belief similarity | 0.90 strengthen, 0.80 supersede |
| Nightly time | 02:00 local |

## Further reading

- [pgvector](https://github.com/pgvector/pgvector) and
  [HNSW](https://arxiv.org/abs/1603.09320): vector storage and index.
- [Matryoshka embeddings](https://arxiv.org/abs/2205.13147) and
  [Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B).
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp): voice transcription.
- [RAG](https://arxiv.org/abs/2005.11401) and
  [Generative Agents](https://arxiv.org/abs/2304.03442): the retrieval and
  reflection patterns behind ask, chat and beliefs.
- [Server-sent events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events):
  chat's streaming transport.
- [Content-addressable storage](https://en.wikipedia.org/wiki/Content-addressable_storage):
  the vault model.
