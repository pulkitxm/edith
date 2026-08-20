# `ed herdr`

Live Herdr sessions on this Mac and on the SSH machines Edith already knows.
`ed herdr` runs `herdr` locally and, over the shared SSH control socket, on
every configured machine. Reach for it when you want a list of panes, or the
exact attach line the Herdr page copies.

A missing `herdr` binary is not a failure. That host is listed with `herdr`
false and an empty agent list, and the command still exits 0. Unknown machines
are the only not-found case.

The Herdr extension does not have to be on for these commands to run. They talk
to the `herdr` CLI, not to the Edith window.

## At a glance

| Command | What it does |
| --- | --- |
| `ed herdr` | Runs `ls`, which is the default subcommand |
| `ed herdr ls` | Live sessions on this Mac and every SSH machine |
| `ed herdr command <pane>` | The attach line for one pane |

`ed herdr list` is an alias for `ed herdr ls`.

## Commands

- [`ed herdr ls`](./ls.md)
- [`ed herdr command`](./command.md)

## Exit codes

| Code | When |
| --- | --- |
| 0 | The listing printed, including when Herdr is missing or no panes are live |
| 2 | The command line was wrong: an unknown flag, or `command` with no pane |
| 3 | `--machine` named no configured machine, or `command` named no pane |

Nothing in this group exits 1 or 4. A down SSH machine is an error string on
that host, not an unavailable CLI.

## Notes and gotchas

- This Mac is `--machine local`. `this-mac`, `thismac` and `mac` are the same
  thing. Any other value is resolved the way `ed machines show` resolves a
  name: exact name, SSH alias, UUID, or a unique prefix.
- Session names come from `herdr session list`. If that command prints nothing
  useful, Edith tries the `default` session.
- The attach line for a remote pane is
  `ssh -tt <target> -- herdr --session <session> agent attach <pane>`. Detach
  inside Herdr with `ctrl+b q`. The server stays up.
- PATH on the far side is prefixed with `$HOME/.local/bin`, `$HOME/.cargo/bin`,
  `/opt/homebrew/bin` and `/usr/local/bin` before `herdr` is called, which is
  where a curl-installed binary usually lives.
- The extension switch is `tabHerdrEnabled`. Prefer
  `ed extensions enable herdr` so the sidebar item appears.

## Where to go next

- [`ed machines`](../machines/README.md) for the SSH directory these commands walk
- [`ed extensions`](../extensions/README.md) to turn the Herdr page on
- [All `ed` commands](../README.md)
