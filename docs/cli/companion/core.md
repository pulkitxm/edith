# `ed companion core`

Reads or edits the standing summary of who you are: the small block that sits in
context on every answer. It is rewritten on the nightly run from the beliefs that
have earned their place, and you can rewrite any section yourself.

Usage:

```
ed companion core [show] [--json] [--endpoint <url>]
ed companion core set <section> <content> [--json] [--endpoint <url>]
```

The six sections are `identity`, `current_situation`, `values`, `open_threads`,
`relationships` and `communication_style`. Anything else is refused rather than
silently filed.

`ed companion core show` (also the bare default) prints each section with its token
count and who last wrote it. `--json` shape: an array of `{section, content, tokens,
updatedAt, updatedBy}`.

`ed companion core set` replaces one section and marks its stored `updatedBy` as
`user`. The nightly rewrite receives the current section text but not that authorship
field, so it can replace a user-written section when the beliefs support a rewrite.
Keeping this editable still lets you correct bad context immediately.

`ed companion core set --json` returns `{section, ok}`.

The set operation overwrites immediately without confirmation. Empty or whitespace
content clears the section. A nightly rewrite reads up to 40 active beliefs and 15
recent episode titles, and leaves the core untouched when no active belief exists.

## Where to go next

- [`ed companion beliefs`](./beliefs.md), what the summary is distilled from
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
