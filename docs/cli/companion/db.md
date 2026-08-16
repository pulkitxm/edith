# `ed companion db`

The maintenance verbs. They exist because of one structural rule: the vault and the
episodes are append-only and immutable, and everything above them is derived and
disposable.

Usage:

```
ed companion db [migrate] [--json] [--endpoint <url>]
ed companion db reindex [--json] [--endpoint <url>]
ed companion db rebuild-derived [--json] [--endpoint <url>]
```

`ed companion db migrate` (also the bare default) applies any migration the backend
has not run. It runs on boot too, so this is for when you deploy without a restart.

`ed companion db reindex` drops the chunks. [`ed companion index`](./index.md) then
embeds every episode again, which is what you want after changing the embedding model
or the chunker.

`ed companion db rebuild-derived` is the bigger hammer and the reason the ladder is
built this way. It drops the chunks, retires every belief and closes every fact,
keeping the episodes untouched, so the next nightly run derives the whole upper
memory again with the current prompts. This is your "I improved the extraction
prompt" button, and it is only cheap because nothing above the episodes was ever the
original.

`--json` shape for `rebuild-derived`: `{chunksDropped, beliefsRetired, factsExpired,
episodesKept}`.

## Where to go next

- [`ed companion index`](./index.md), what rebuilds the chunks
- [`ed companion export`](./export.md) and [`ed companion wipe`](./wipe.md), the data itself rather than what is derived from it
- [Memory](./concepts-memory.md), why the ladder is arranged this way
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
