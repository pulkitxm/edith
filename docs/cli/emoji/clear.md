# `ed emoji clear`

Forgets the frequently used emoji, the whole ledger at once.

Usage:

```
ed emoji clear [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments, and there is no `--yes`. Unlike
`ed color clear` and `ed clipboard clear` this verb has no preview step: it
applies as soon as you run it.

`--json` shape:

```json
{
  "cleared": 3
}
```

`cleared` is how many emoji were in the ledger before it was emptied, not how
many were shown in the picker. The ledger holds up to 200 entries while
`emojiFrequentCount` decides how many of them are pinned above the grid, so this
number is usually larger than the row you were looking at.

Examples:

```
ed emoji clear
ed emoji clear --json
```

```
$ ed emoji clear
cleared 3 frequently used emoji
```

Behaviour: this writes an empty ledger back to the `emojiUsage` key of the
`com.pulkit.edith.shared` defaults suite, so the key stays present and simply
holds no entries; it is not removed the way `ed color clear` removes its
history. It then posts the same `settingsChanged` notification `ed config set`
sends. A running picker re-reads the ledger on that notification, so an open
panel loses its frequently used row straight away rather than at the next
restart. The post is fire and forget, so the command needs nothing running and
exits 0 either way.

Clearing an already empty ledger is reported as `cleared 0 frequently used
emoji` rather than as an error. Nothing else is touched: the catalog is bundled
and read-only, your skin tone stays where it was, and the Emoji Picker extension
stays on or off as it was. `clear` checks neither the extension nor the app, so
it never exits 4.

There is no per-emoji removal here. To drop a single emoji from the row without
losing the rest, right-click it in the picker and choose Remove from frequently
used, which is the only surface that can forget one.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | The ledger was emptied, including when it was already empty. |
| 2 | The command line was invalid. |

## Where to go next

- [`ed emoji ls`](./ls.md), whose `--frequent` reads this ledger
- [`ed emoji`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
