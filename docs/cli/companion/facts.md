# `ed companion facts`

Structured claims with two independent timelines: when something was true in the
world, and when the system believed it. Keeping both is cheap on day one and
impossible to add later, which is why it is here rather than deferred.

Usage:

```
ed companion facts [--as-of <date>] [--timeline valid|believed] [--limit <n>]
                   [--json] [--endpoint <url>]
```

`--timeline` defaults to `valid`, `--limit` defaults to 30 and must be positive, and
any value other than `valid` or `believed` is refused. Without `--as-of` you get the
newest records without an as-of filter. With it, the two timelines answer
genuinely different questions:

`--as-of` accepts `YYYY-MM-DD` or a full RFC 3339 timestamp. The backend currently
treats an unparseable value as though the option were omitted, so validate scripted
input before relying on an as-of result.

| Timeline | Question it answers |
| --- | --- |
| `valid` | What was actually true then. |
| `believed` | What the system thought was true then. |

The gap between those two is where most of the self-knowledge lives. "You were
unhappy in March" and "in March, you thought you were fine" are different sentences,
and no vector search can tell them apart.

Contradictions are not bugs here. When a new fact conflicts with an open one, the old
one does not get deleted: its validity window is closed, `superseded_by` points at
what replaced it, and the change itself becomes a thing you can retrieve. Both
queries use `coalesce` on the open end, because a naive `BETWEEN` silently misses
every currently true row.

`--json` shape: an array of `{id, subject, predicate, object, validFrom, validTo,
createdAt, expiredAt, supersededBy}`.

## Where to go next

- [`ed companion entities`](./entities.md), the things these facts relate
- [`ed companion why`](./why.md), the evidence under any of them
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
