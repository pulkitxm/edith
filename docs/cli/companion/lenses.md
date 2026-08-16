# `ed companion lenses`

Prints what each lens has learned about being useful to you in its role. Not what it
knows about you: the shared memory holds that, and fragmenting memory per lens would
be a mistake. This is the note that records when you take a nudge and when you ignore
one, when you want to be left alone, and what kind of pushback lands.

Usage:

```
ed companion lenses [--json] [--endpoint <url>]
```

`--json` shape: an array of `{persona, content, updatedAt, updatedBy}`.

Who writes these matters. The nightly pass does, from up to 25 turns with that lens
in the previous seven days. It needs at least three turns before it writes anything,
and the note is kept short. A lens never edits its own note mid conversation, for the
same reason the chat path cannot write to beliefs: your worst moments should be
recorded, and should not get to rewrite the model of who you are without a cooler
pass over them.

## Where to go next

- [`ed companion personas`](./personas.md), the specs the lenses run on
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
