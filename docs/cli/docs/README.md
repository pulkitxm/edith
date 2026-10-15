# `ed docs`

The `ed` reference, the same pages you are reading, bundled into Edith. It
lists and prints pages, and it answers "which command does this?" for a
plain-language request. The Docs page in the app shows the same pages with an
Ask bar that runs `ed docs ask` and jumps to the section it picks.

`ed docs ask` uses Jev when a TypeSafe key is saved in Settings > Jev, and a
local search over command names, titles, headings and summaries otherwise. It
never needs the app or the background agent to answer: when Jev is off, missing,
out of credits or slow, the local search answers instead.

## At a glance

| Command | What it does |
| --- | --- |
| `ed docs` | Runs `ls`, which is the default subcommand |
| `ed docs ls` | Every page, or one group's pages |
| `ed docs show <page-or-command>` | Print one page as Markdown |
| `ed docs ask <request>` | Rank the commands that handle a request |

`ed docs list` is an alias for `ed docs ls`.

## Commands

- [`ed docs ls`](./ls.md)
- [`ed docs show`](./show.md)
- [`ed docs ask`](./ask.md)

## Exit codes

| Code | When |
| --- | --- |
| 0 | The listing, page or ranking printed, including a ranking with no picks |
| 2 | The command line was wrong, such as `show` or `ask` with nothing to look up |
| 3 | `--group` named no group, or `show` matched no page or command |
| 4 | The bundled reference is missing from this install |

- [All command groups](../README.md)
