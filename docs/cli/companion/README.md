# `ed companion`

`ed companion` talks to Edith's local memory backend. The companion stores
Markdown notes as append-only episodes in Postgres, keeps the original note in
its vault, and deduplicates sources by their SHA-256 content hash.

Run the backend with docker compose from `apps/companion`. The CLI reaches it
directly on this Mac or through an `ed machines` port forward. Pass
`--endpoint` for one invocation, set `EDITH_COMPANION_URL` for a shell, or use
the default `http://127.0.0.1:4820`.

For the machinery behind these commands, start at
[how the companion works](./concepts.md), the overview, then go deep:
[memory](./concepts-memory.md), [ingestion](./concepts-ingestion.md),
[chunks, embeddings and search](./concepts-search.md),
[asking and chatting](./concepts-chat.md),
[the learning loop](./concepts-learning.md),
[reasoning it does on its own](./concepts-brain.md) and
[not being a yes-man](./concepts-friend.md).

## At a glance

| Command | What it does |
| --- | --- |
| `ed companion` | Runs `ed companion status`, the default subcommand. |
| `ed companion status` | Counts stored records and episodes waiting to be indexed. |
| `ed companion doctor` | Checks Postgres, migrations, pgvector, Redis and the vault. |
| `ed companion search <query>` | Searches indexed memory with hybrid retrieval. |
| `ed companion index` | Embeds episodes that are waiting to be indexed. |
| `ed companion ingest <path>` | Sends a note, recording, photo, video or PDF, or a folder of them, to the backend. |
| `ed companion episodes` | Lists recent episodes, newest first. |
| `ed companion episode <id>` | Reads one episode in full, body included. |
| `ed companion chat <message>` | Talks with the companion, streamed as it thinks. |
| `ed companion conversations` | Lists chats, or replays one by id. |
| `ed companion forget <id>` | Deletes a conversation and its messages. |
| `ed companion nightly` | Runs the nightly learning pipeline right now. |
| `ed companion reason` | Shows or changes the reasoning provider, model and API key. |
| `ed companion ask <question>` | Answers from your own memory, through one lens. |
| `ed companion council <question>` | Asks several lenses and finds the crux they disagree on. |
| `ed companion personas` | Lists the lenses that can answer, and how each thinks. |
| `ed companion lenses` | What each lens learned about being useful to you. |
| `ed companion core` | Reads or edits the standing summary of who you are. |
| `ed companion why <id>` | Prints the whole chain behind a belief, theory or claim. |
| `ed companion hypotheses` | The theories it holds about you, and how they are faring. |
| `ed companion predictions` | What it expects to happen, and what did. |
| `ed companion commitments` | What you said you would do, and what happened. |
| `ed companion discrepancies` | Where your account and the record parted company. |
| `ed companion calibration` | How your account compares with the record, both directions. |
| `ed companion inquire` | The questions it wants to ask you, and your answers. |
| `ed companion entities` | The people, projects and places it knows, with every spelling. |
| `ed companion eval` | Scores the friend layer against the cases it should fail. |
| `ed companion standup <file>` | Records a standup and checks it against the record. |
| `ed companion machines` | Where the stack runs, and what each machine can do. |
| `ed companion hosts` | Machines that could run the companion, and what each one needs. |
| `ed companion deploy` | Choose the machine that runs it, and bring it up there. |
| `ed companion stack` | Start, stop, restart, log and inspect the stack on its host. |
| `ed companion baselines` | Your own delivery baselines, which every signal is measured against. |
| `ed companion connectors` | Tokens for GitHub and Notion, and imports for calendar, music and YouTube. |
| `ed companion facts` | What was true, and what it believed at the time. |
| `ed companion correct <id>` | Retires a wrong belief, or rewrites it in your words. |
| `ed companion weekly` | The wider weekly pass: relate, reopen, retire. |
| `ed companion db` | Migrate, reindex, or rebuild everything derived. |

## Commands

- [`ed companion hosts`](./hosts.md)
- [`ed companion deploy`](./deploy.md)
- [`ed companion stack`](./stack.md)
- [`ed companion status`](./status.md)
- [`ed companion doctor`](./doctor.md)
- [`ed companion search`](./search.md)
- [`ed companion index`](./index.md)
- [`ed companion ingest`](./ingest.md)
- [`ed companion episodes`](./episodes.md)
- [`ed companion sync`](./sync.md)
- [`ed companion observations`](./observations.md)
- [`ed companion reflect`](./reflect.md)
- [`ed companion beliefs`](./beliefs.md)
- [`ed companion ask`](./ask.md)
- [`ed companion extract`](./extract.md)
- [`ed companion claims`](./claims.md)
- [`ed companion corroborate`](./corroborate.md)
- [`ed companion runs`](./runs.md)
- [`ed companion chat`](./chat.md)
- [`ed companion conversations`](./conversations.md)
- [`ed companion forget`](./forget.md)
- [`ed companion episode`](./episode.md)
- [`ed companion nightly`](./nightly.md)
- [`ed companion reason`](./reason.md)
- [`ed companion personas`](./personas.md)
- [`ed companion council`](./council.md)
- [`ed companion lenses`](./lenses.md)
- [`ed companion core`](./core.md)
- [`ed companion why`](./why.md)
- [`ed companion hypotheses`](./hypotheses.md)
- [`ed companion predictions`](./predictions.md)
- [`ed companion commitments`](./commitments.md)
- [`ed companion discrepancies`](./discrepancies.md)
- [`ed companion calibration`](./calibration.md)
- [`ed companion inquire`](./inquire.md)
- [`ed companion entities`](./entities.md)
- [`ed companion eval`](./eval.md)
- [`ed companion standup`](./standup.md)
- [`ed companion machines`](./machines.md)
- [`ed companion baselines`](./baselines.md)
- [`ed companion connectors`](./connectors.md)
- [`ed companion facts`](./facts.md)
- [`ed companion correct`](./correct.md)
- [`ed companion weekly`](./weekly.md)
- [`ed companion db`](./db.md)

## Concept pages

- [How the companion works](./concepts.md)
- [Memory](./concepts-memory.md)
- [Ingestion](./concepts-ingestion.md)
- [Chunks, embeddings and search](./concepts-search.md)
- [Asking and chatting](./concepts-chat.md)
- [The learning loop](./concepts-learning.md)
- [Reasoning it does on its own](./concepts-brain.md)
- [Not being a yes-man](./concepts-friend.md)

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success, including a reachable doctor report whose `ok` is false. |
| `1` | General failure. |
| `2` | Bad usage, including a missing Markdown path or a non-positive limit. |
| `4` | The companion backend is unreachable or returned an unusable response. |

## Notes and gotchas

`--endpoint` wins over `EDITH_COMPANION_URL`, which wins over
`http://127.0.0.1:4820`. A saved machine forward can put a remote companion on
that local address: run `ed machines forwards on <machine> <n>`, then
`ed companion status`.

Each Markdown file must be no larger than 2MB, recordings, photos and PDFs no
larger than 48MB, and video no larger than 768MB. Anything bigger is skipped
before any request, and note uploads are split into batches of 200 files. The
backend deduplicates by SHA-256 of the content, so ingesting the same file again
is safe and returns `duplicate` with the original episode id.

Search and indexing need the Ollama service to be reachable and the configured
embedding model to be pulled before the first request.

## Where to go next

Use [`ed machines`](../machines/README.md) to create and open a port forward. Read
[conventions and contracts](../conventions.md) for JSON, stdout, stderr and exit
code guarantees shared by every command.

- [All `ed` commands](../README.md)
