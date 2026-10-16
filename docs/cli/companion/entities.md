# `ed companion entities`

The people, projects, places, organisations and other named things the companion has
resolved, each with every spelling it has seen. Embeddings smear proper nouns, so
entities are what keep one person from becoming two.

Usage:

```
ed companion entities [--limit <n>] [--json] [--endpoint <url>]
```

Aliases span scripts deliberately. A name in Devanagari, the same name romanised and
the two ways you habitually misspell it resolve to one entity, which is where
multilingual retrieval otherwise dies. Retrofitting that means re-resolving the whole
graph, so it is done at extraction time.

`--json` shape: an array of `{id, kind, canonicalName, aliases, mentionCount,
firstSeen, lastSeen}`.

Kinds are `person`, `project`, `place`, `organisation` and `thing`. `--limit`
defaults to 30 and must be positive.

Entities are also a retrieval channel: a question that names one walks from the
entity to the episodes that mention it, alongside vector and keyword search.

## Where to go next

- [`ed companion search`](./search.md), the channels these feed
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
