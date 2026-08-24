# `ed companion db`

The maintenance verbs. They exist because of one structural rule: the vault and the
episodes are append-only and immutable, and everything above them is derived and
disposable.

Usage:

```
ed companion db [migrate] [--json] [--endpoint <url>]
ed companion db reindex [--yes] [--json] [--endpoint <url>]
ed companion db rebuild-derived [--yes] [--json] [--endpoint <url>]
```

`ed companion db migrate` (also the bare default) applies any migration the backend
has not run. It runs on boot too, so this is for when you deploy without a restart.

`ed companion db reindex` drops the chunks and then embeds every episode again, which
is what you want after changing the embedding model or the chunker.

`ed companion db rebuild-derived` is the bigger hammer and the reason the ladder is
built this way. It drops the chunks, retires every belief and closes every fact,
keeping the episodes untouched, so the next nightly run derives the whole upper
memory again with the current prompts. This is your "I improved the extraction
prompt" button, and it is only cheap because nothing above the episodes was ever the
original.

Both `reindex` and `rebuild-derived` are destructive maintenance operations.
They do not touch episodes or vault originals, but search is incomplete until
indexing finishes. `rebuild-derived` also retires active, contested and already
superseded beliefs, and expires every open fact. Export first when you need an
easy rollback of derived state.

Without `--yes`, either command prints the exact records it would invalidate and
changes nothing. Add `--yes` to apply the preview. The app presents the same targets
in a typed confirmation sheet before either Settings button runs.

Every maintenance JSON response includes `action`. A preview also returns
`{targets,applied:false,changed:false}`. Confirmed `reindex` adds
`{chunksDropped,episodesIndexed,chunksCreated}`, while confirmed `rebuild-derived`
adds `{chunksDropped,beliefsRetired,factsExpired,episodesKept}`. `migrate` keeps its
nullable count fields because it is non-destructive and does not need confirmation.

## Where to go next

- [`ed companion index`](./index.md), what rebuilds the chunks
- [`ed companion export`](./export.md) and [`ed companion wipe`](./wipe.md), the data itself rather than what is derived from it
- [Memory](./concepts-memory.md), why the ladder is arranged this way
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
