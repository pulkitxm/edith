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

`ed companion core set` replaces one section and marks it as yours, so the next
nightly rewrite can see that a human wrote it. Keeping this editable is not a
convenience: if the system forms a wrong idea of you and you cannot correct it, every
later answer inherits the error.

## Where to go next

- [`ed companion beliefs`](./beliefs.md), what the summary is distilled from
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
