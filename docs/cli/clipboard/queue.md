# `ed clipboard queue`

Collects clipboard history entries and pastes them in first-in, first-out order.
The queue lives in the running Edith menu bar helper and is cleared whenever the
helper restarts.

## Enable automatic queueing

```bash
ed extensions enable clipboard
ed config set pasteQueueEnabled true
```

Clipboard capture and automatic queueing are separate settings. Both must be on
for newly captured entries to join the queue. Manual `queue add` commands work
with automatic queueing turned off.

## Add and inspect entries

```bash
ed clipboard ls
ed clipboard queue add 1
ed clipboard queue ls
```

The history index passed to `ed clipboard queue add` is one-based. Adding an
entry that is already queued moves it to the back, which lets you choose the
paste order. `ed clipboard queue ls` shows the entry IDs accepted by `rm`.

## Paste the next entry

```bash
ed clipboard queue next
```

`ed clipboard queue next` copies the oldest queued entry to the pasteboard,
sends Command-V to the active app, and removes the entry from the queue.
Accessibility permission is required. If the permission is missing, the entry
stays queued.

## Remove entries

```bash
ed clipboard queue rm <entry-id>
ed clipboard queue clear
```

`ed clipboard queue rm` removes one queued entry by the ID shown in the queue
listing. `ed clipboard queue clear` empties the in-memory queue without changing
clipboard history.

## JSON

Every queue command accepts `--json`:

```bash
ed clipboard queue ls --json
ed clipboard queue add 1 --json
ed clipboard queue next --json
ed clipboard queue rm <entry-id> --json
ed clipboard queue clear --json
```

Listings are arrays ordered from the next entry to paste through the newest
queued entry. Mutating commands report the affected entry or count and the
number of entries remaining.

## See also

- [`ed clipboard`](./README.md), the rest of the clipboard history commands
- [`ed permissions`](../permissions/README.md), to grant Accessibility access
- [`ed config`](../config/README.md), to inspect or change `pasteQueueEnabled`
- [All `ed` commands](../README.md)
