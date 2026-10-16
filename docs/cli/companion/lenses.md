# `ed companion lenses`

Prints each lens's short nightly note about how to be useful in its role. Shared
memory still holds what the companion knows about you; lens notes do not fragment
that memory.

Usage:

```
ed companion lenses [--json] [--endpoint <url>]
```

`--json` shape: an array of `{persona, content, updatedAt, updatedBy}`.

The nightly pass writes these from up to 25 turns with that lens in the previous
seven days. For each turn it sees your query, grounding score, abstention flag and
date, but not the answer or an explicit reaction from you. It needs at least three
turns before writing and trims the result to 90 words. A lens never edits its own
note mid conversation.

## Where to go next

- [`ed companion personas`](./personas.md), the specs the lenses run on
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
