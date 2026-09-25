# Terminals in agent tabs

Every tab on the Herdr page can carry its own terminals. They open in a panel
that floats over the bottom of the tab, so the agents underneath keep their
size and never reflow, and the panel can be dragged up to cover the whole tab.

| Keys | What they do |
| --- | --- |
| `` ⌃` `` or `⌘J` | Show or hide the panel |
| `` ⌃⇧` `` | Open another terminal for the focused agent |

The terminals are listed on the right of the panel, named after whatever is in
the foreground (`zsh`, `npm run dev`, `python3 -m http.server`), with the folder
and, for another machine, its name underneath. A dot marks a terminal that is
running something.

## Where a terminal opens

A terminal belongs to one agent in the tab and opens on that agent's machine, in
that agent's folder. When a tab shows several agents side by side, `+` asks which
one. The board opens terminals on this Mac in the home folder.

Each terminal is a real Herdr tab in a workspace called `Edith-terminals` on that
machine, created the first time it is needed. Closing a terminal in Edith closes
its Herdr tab, and Herdr removes the workspace once its last tab is gone. A
terminal whose shell exits in Herdr disappears from Edith as well.

Edith keeps that workspace in sync on every machine. A tab you open in
`Edith-terminals` from Herdr itself, or one left running when Edith quit, shows
up in the tab whose agent works in the same folder on the same machine, and on
the board when no such tab is open. It moves over once you open that agent.

History lives in Herdr, so the scrollbar on the right of a terminal follows
Herdr's scrollback: it moves as you scroll with the wheel, and dragging it or
clicking the track jumps there.

## Closing terminals and tabs

The `×` next to a terminal closes it and its Herdr tab. When it is running
something, Edith asks first and names what would stop.

Closing an Edith tab closes its terminals and their Herdr tabs. When one of them
is running something, Edith asks first and names what would stop. Tabs that are
merged or moved carry their terminals along. When a tab's only agent leaves the
tab strip, for example into its own window, its terminals move to the board
instead of stopping.

Closing an agent from its details sends it two `ctrl+c` presses, waits for its
shell to come back (interrupting once more if it keeps running), then closes its
Herdr pane.

## Settings

The gear in the panel header edits these, and `ed config` reads and writes the
same keys.

| Key | Values | Default | What it does |
| --- | --- | --- | --- |
| `herdrTerminalMouse` | `scroll`, `buttons` | `scroll` | `scroll` only sends the wheel. `buttons` also sends clicks and drags to apps that use the mouse. Pointer moves are never sent |
| `herdrTerminalFontSize` | 9 to 24 | 13 | Text size |
| `herdrTerminalStartFolder` | `agent`, `home` | `agent` | Where a new terminal starts |
| `herdrTerminalStartupCommand` | any command | empty | Runs in every new terminal |
| `herdrTerminalConfirmClose` | `true`, `false` | `true` | Ask before closing a terminal, or a tab, that is running something |

```
ed config set herdrTerminalStartupCommand 'source .venv/bin/activate'
ed config set herdrTerminalMouse buttons
```

## Where to go next

- [`ed config`](../config/README.md), for the settings above
- [`ed herdr`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
