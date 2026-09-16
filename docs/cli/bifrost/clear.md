# `ed bifrost clear`

Forgets the frequently opened ledger, the record of what you pick in the bar.

Usage:

```
ed bifrost clear [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments. The plain response counts what went:

```
$ ed bifrost clear
cleared 37 frequently opened applications
```

The JSON response has one stable field:

```json
{
  "cleared": 37
}
```

`cleared` is the number of entries the ledger held, not the number of times you
opened them. Clearing an already empty ledger is a success that reports `0`.

The ledger lives at the `bifrostUsage` key of the shared defaults suite
(`com.pulkit.edith.shared`) as a JSON-encoded list of
`{target, count, lastUsedAt}`. It is what ranks an empty query, what nudges a
frequent application above an equally good match, and the only part of Bifrost
that reflects your habits. It is backed up with your settings, so it survives a
reinstall, and this is the only way to empty it from the command line. There is
no per-application forget.

The command posts `settingsChanged`, so an open bar drops what it was showing
for an empty query straight away. The post is fire and forget, so the command
does not fail when nothing is listening.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | The ledger was cleared, including when it was already empty. |
| 2 | The command line was invalid. |

It cannot exit 3 or 4. The command is not gated on the extension and does not
need Edith running, because it only writes a defaults key, and the index itself
is untouched: what Bifrost can find does not change, only what it puts first.

## Where to go next

- [`ed bifrost ls`](./ls.md), to see the index the ledger ranks
- [`ed bifrost`](./README.md), the rest of this group
- [`ed config`](../config/README.md), for the settings that are not this ledger
- [All `ed` commands](../README.md)
