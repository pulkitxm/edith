# Chunks, embeddings and search

Part of [how the companion works](./concepts.md), under
[`ed companion`](./README.md) in [the CLI reference](../README.md). This page
explains how stored text becomes findable by meaning: why episodes are cut
into chunks, what an embedding actually is, and how the database finds the
nearest ones fast. It assumes no machine-learning background.

## Why search by meaning at all

Keyword search finds the word you typed. Ask "how did the auth work go?" and
a keyword engine misses the note that says "shipped the session token
refactor", because none of the words match. The companion's whole value is
answering questions in your words about notes in your words, so it searches
by **meaning**: it turns both the question and every piece of memory into
numbers such that similar meanings produce similar numbers, then finds the
closest pieces. That is the entire trick, and the rest of this page unpacks
each part of it.

## Step one: cut episodes into chunks

An episode can be ten words or ten pages. Searching whole episodes would be
too coarse: a long journal entry that mentions billing once would either
drown the question in irrelevant text or be missed entirely. So episodes are
cut into **chunks**, pieces big enough to carry a coherent thought and small
enough to be about one thing.

The algorithm is simple and deterministic:

1. Split the body into paragraphs (runs of text separated by blank lines).
2. Pack consecutive paragraphs into a chunk, keeping their blank-line
   separators, until adding the next paragraph would push past 1600
   characters. Then start a new chunk.
3. A single paragraph longer than 1600 characters is cut at exactly 1600,
   as many times as needed.

Three properties worth noticing:

- **Boundaries follow your writing.** Paragraphs are how you grouped your
  own thoughts, so chunks tend to be self-contained.
- **Zero overlap.** Many retrieval systems repeat the last few sentences of
  each chunk at the start of the next so a thought split across a boundary
  is still findable. The companion does not; chunks are disjoint, and
  concatenating them reproduces the episode exactly. Simpler, cheaper,
  slightly worse at boundary-straddling thoughts.
- **Characters, not tokens.** 1600 characters is roughly 250 to 400 English
  words. A rough token estimate (characters divided by 4) is stored per
  chunk but nothing uses it yet.

## Step two: what an embedding is

An **embedding** is a list of numbers that represents the meaning of a piece
of text. Think of it as coordinates: the way `(latitude, longitude)` places a
city on a map with 2 numbers, an embedding places a sentence in a "meaning
space" with hundreds of numbers. The embedding model, a neural network
trained on enormous amounts of text, is the thing that assigns those
coordinates, and its one crucial promise is: **texts with similar meaning
land near each other.** "Shipped the session token refactor" and "how did the
auth work go?" end up close, even though they share almost no words, because
the model has learned from usage that these phrases live in the same
neighbourhood of meaning.

Nothing mystical is stored: for every chunk, the companion keeps its text
plus its coordinates, a fixed-length list of numbers.

## The model, and its numbers

The companion runs the embedding model locally through **Ollama**, a small
server that downloads and runs open ML models on your own machine, so your
notes never leave your infrastructure to be embedded. The model is
`qwen3-embedding:0.6b`, a 0.6-billion-parameter embedding model that produces
1024 numbers per text.

The companion keeps only the **first 512** of those 1024 numbers. That
sounds like throwing half the meaning away, but this family of models is
trained with a technique called Matryoshka representation learning (named
after the nesting dolls): the training deliberately front-loads meaning into
the early dimensions, so a truncated prefix is itself a valid, slightly
coarser embedding. Half the numbers means half the storage and roughly twice
the search speed, for a small accuracy cost.

After truncation each vector is **normalized**: scaled so its overall length
is exactly 1. Picture every embedding as an arrow from the origin; after
normalization all arrows have the same length and only their **direction**
differs. That matters for the next step.

## Step three: measuring closeness

With every arrow the same length, "how similar are two texts?" becomes "how
small is the angle between their arrows?". The standard measure is **cosine
similarity**: 1.0 means the arrows point the same way (same meaning), 0
means unrelated, and the database's `<=>` operator computes the equivalent
cosine **distance** (smaller is closer). Every search in the companion, and
also the belief life-cycle in [the learning loop](./concepts-learning.md),
is this one operation: embed something, find the arrows with the smallest
angle to it.

## Step four: finding vector candidates fast

Comparing the question against every chunk works, but grows linearly: at a
hundred thousand chunks every search touches a hundred thousand vectors. The
fix is an index called **HNSW** (hierarchical navigable small world), which
is easiest to picture as a highway system over the points:

- Every chunk is connected to a handful of its nearest neighbours (local
  roads).
- A sparser layer connects points across larger distances (highways), and a
  few sparser layers sit above that.
- A search starts on the top layer, hops greedily toward the target, then
  drops down a layer and refines, repeating until it lands among the true
  nearest neighbours.

The result is **approximate** nearest-neighbour search: it very occasionally
misses the single closest chunk, but it answers in milliseconds regardless
of memory size, which is the right trade for "find me 8 relevant memories".

Storage-wise, the vectors live in Postgres through the pgvector extension as
`halfvec(512)`: 512 numbers at 16-bit precision instead of the usual 32-bit,
halving storage and index size again. Embedding coordinates do not need many
digits of precision; direction is what carries the meaning. Chunks have an
HNSW index over their vectors, and so do beliefs.

## Step five: fuse the retrieval channels

Vector similarity is only one channel now. A search builds a candidate pool
from three independent views of the same memory:

1. The vector channel asks HNSW for up to 50 semantically nearest chunks.
2. The keyword channel asks Postgres full-text search, with a literal substring
   fallback, for up to 50 lexical matches.
3. The graph channel follows entity names and aliases to mentioned episodes,
   then takes up to 25 recent chunks from them.

Each list contributes reciprocal-rank points, which reward appearing near the
top without pretending scores from different channels are directly comparable.
The graph contribution is weighted at 0.7. The combined score is then adjusted
by chunk salience and a gentle recency curve whose half-life is roughly 180
days. Old memory can still win; age never makes its score zero.

If `RERANK_URL` is configured and there are more candidates than requested,
the companion sends the fused pool to the configured reranker, default model
`qwen3-reranker:0.6b`, and uses those relevance scores for final order. A
missing reranker is an optional doctor check and leaves the fused order intact.
A reranker failure also falls back to fusion rather than failing the search.

Persona policies can constrain source kinds and time windows, change salience
weighting, include contested beliefs, or disable the graph, belief and
observation channels. The plain `ed companion search` command uses the default
policy: all episode kinds, no time cutoff, graph enabled, 8 final chunks.

## Step six: when indexing runs

Chunking plus embedding is called **indexing**, and its trigger model is
unusually simple. There is no file watcher, no change detection, no queue.
An episode "needs indexing" if and only if it has **zero chunks**, which is a
correct definition because episodes are immutable (see
[memory](./concepts-memory.md)): once chunked, an episode can never change
and never needs re-chunking.

Indexing runs on three occasions:

1. In the background, right after any ingest that stored something new.
2. On demand, via `POST /v1/index` or `ed companion index`.
3. As a step of the nightly run.

Each pass picks up to 500 pending episodes, oldest occurrence first, embeds
their chunks in batches of 16 (one Ollama call per batch), and commits each
episode's chunks in one transaction. If Ollama is down, the error surfaces
as HTTP 502 and, in the CLI, as a plain "the Ollama embedding service is
unavailable", distinct from a database failure. Episodes that fail simply
remain pending and are retried by the next pass.

`ed companion status` counts this pipeline: `chunks` is the indexed total and
`pendingEpisodes` is the backlog.

## What search does, end to end

`ed companion search "billing migration"` or `GET /v1/search`:

1. Embed the query with the same model (this is essential: coordinates are
   only comparable when the same model assigned them).
2. Ask the HNSW index for the nearest chunk vectors (default 8, up to 50).
3. Return each chunk with its episode title, date, kind, a snippet, and the
   similarity score.

The returned `score` is the optional reranker score when reranking ran,
otherwise the fused score. Search telemetry records the candidate channels,
their component scores and final ranks. The current public search response
still labels every result `kind: "chunk"` and sets `ord` to `0`; use
`episodeId` and `chunkId` as the stable identities rather than treating those
two compatibility fields as source metadata.

## Reading on

- [Asking and chatting](./concepts-chat.md): what happens to those 8 chunks
  once a language model gets involved.
- [The learning loop](./concepts-learning.md): the same cosine machinery
  driving belief formation.
