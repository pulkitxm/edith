# `ed companion correct`

Retires a belief that is wrong, or rewrites it in your own words. This is
non-negotiable rather than a convenience: if the system forms a wrong belief about
you and you cannot correct it, every later answer inherits the error and you stop
trusting the whole thing.

Usage:

```
ed companion correct <id> --retire [--json] [--endpoint <url>]
ed companion correct <id> --edit "<what it should say>" [--json] [--endpoint <url>]
```

`--retire` marks it retired. `--edit` writes a new belief carrying the same evidence,
marked as yours rather than the extractor's, and supersedes the old one with a
pointer back to it. Neither deletes anything: the append-only rule holds all the way
up, so `ed companion why` can still show what was believed and when it stopped being
believed.

Find the id with [`ed companion beliefs`](./beliefs.md), and read the evidence behind
it with [`ed companion why`](./why.md) before you decide. Sometimes the belief is
right and the surprise is the point.

At least one of `--retire` or `--edit` is required. An edit must contain more
than five non-whitespace characters because the backend embeds the replacement.
If both flags are passed with a valid edit, the edit takes precedence and the
old belief is superseded rather than retired. JSON output is
`{id,status,statement}`; for an edit, `id` is the new replacement belief.

## Where to go next

- [`ed companion beliefs`](./beliefs.md), what it currently holds
- [`ed companion why`](./why.md), the chain behind one of them
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
