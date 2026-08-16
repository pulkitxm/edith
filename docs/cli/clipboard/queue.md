# `ed clipboard queue`

Controls the paste queue held by the running Edith menu bar helper. The queue
contains clipboard entry ids, not copies of the data, so the history must still
contain the entry when `next` runs.

```
ed clipboard queue ls
ed clipboard queue add <history-index>
ed clipboard queue rm <entry-id>
ed clipboard queue next
ed clipboard queue clear
```

## Commands

| Command | What it does |
| --- | --- |
| `ls` | List queued entries, oldest first. `list` is an alias. |
| `add <history-index>` | Append an entry from `ed clipboard ls` to the queue. |
| `rm <entry-id>` | Remove every queued occurrence of an id. |
| `next` | Put the oldest valid entry on the pasteboard and synthesize Command-V. |
| `clear` | Remove every queued id. |

Every leaf accepts `--json`. `ls --json` returns an object with `count` and an
`entries` array. Each entry has `id`, `kind`, `preview` and `sourceApp`. `next`
returns `pasted` and `remaining`; `clear` returns `removed`.

The Clipboard extension must be enabled, and the queue setting must be on:

```
ed extensions enable clipboard
ed config set pasteQueueEnabled true
```

The extension command enables clipboard capture; the config command enables
queueing for new captures.

New clipboard captures join the queue while the setting is on. The queue is
in-memory and is cleared when the helper restarts. The clipboard history itself
is persistent, so `add` can rebuild the queue from its numbered entries.

The commands need the menu bar helper because that process owns the queue and
the paste action. If Accessibility is not granted, `next` may put the entry on
the pasteboard but macOS can refuse the synthesized paste.

## Exit codes

| Code | When |
| --- | --- |
| 0 | The queue was listed or changed. An empty list and an empty `next` are successful. |
| 2 | The command line was invalid, including a malformed history index. |
| 3 | A history index or entry id could not be found. |
| 4 | The menu bar helper is not running, or the Clipboard extension is off. |

## Where to go next

- [`ed clipboard`](./README.md) for the persistent history
- [`ed config`](../config/README.md) for queue and hotkey settings
- [All `ed` commands](../README.md)
