# `ed browser`

`ed browser` drives the notch browser in the menu bar app: the open tabs, the
address bar, reload, the Chrome profile attached to it, and the detach that
clears that profile's website data.

Every command talks to the running menu bar app. `ls` only reads. `navigate`,
`reload`, `sync`, `profile`, `tab`, `duplicate`, and `reopen` change the live
browser. `close`, `close-others`, `close-right`, and `detach` print a plan and
wait for `--yes`. `ed browser` with nothing after it is `ed browser ls`.

## At a glance

| Command | What it does |
| --- | --- |
| `ed browser` | Runs `ed browser ls`. |
| `ed browser ls` | Lists tabs, the attached profile, and the profiles Chrome has. |
| `ed browser navigate <address>` | Loads an address in a tab. |
| `ed browser reload` | Reloads a tab. |
| `ed browser copy` | Copies a tab address to the clipboard. |
| `ed browser close` | Previews, then closes a tab with `--yes`. |
| `ed browser close-others` | Previews, then closes the other tabs with `--yes`. |
| `ed browser close-right` | Previews, then closes tabs to the right with `--yes`. |
| `ed browser reopen` | Reopens the last closed tab. |
| `ed browser duplicate` | Duplicates a tab. |
| `ed browser sync` | Imports the attached Chrome profile again. |
| `ed browser profile <name>` | Attaches a Chrome profile. |
| `ed browser detach` | Previews, then detaches and clears website data with `--yes`. |
| `ed browser tab [address]` | Opens a new tab. |

`ed browser list` is the same command as `ed browser ls`.

## Commands

- [`ed browser ls`](./ls.md)
- [`ed browser navigate`](./navigate.md)
- [`ed browser reload`](./reload.md)
- [`ed browser copy`](./copy.md)
- [`ed browser close`](./close.md)
- [`ed browser close-others`](./close-others.md)
- [`ed browser close-right`](./close-right.md)
- [`ed browser reopen`](./reopen.md)
- [`ed browser duplicate`](./duplicate.md)
- [`ed browser sync`](./sync.md)
- [`ed browser profile`](./profile.md)
- [`ed browser detach`](./detach.md)
- [`ed browser tab`](./tab.md)

## Exit codes

| Code | When this group produces it |
| --- | --- |
| 0 | The listing or plan printed, or the browser applied the request. |
| 1 | The browser rejected the request, or the clipboard could not be set. |
| 3 | `--tab` did not match an open tab. |
| 4 | The menu bar app is not running, or the notch browser extension is off. |

## See also

- [`ed browser ls`](./ls.md)
- [`ed`](../README.md)
