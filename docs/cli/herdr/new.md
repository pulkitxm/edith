# `ed herdr new`

Creates a terminal in the Herdr session on this Mac or on one SSH machine.

```
ed herdr new [--machine <name>] [--session <name>] [--workspace <id>]
             [--cwd <path>] [--label <text>] [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--machine <name>` | machine name, alias, UUID, unique prefix, or `local` | this Mac | Where the terminal is created |
| `--session <name>` | herdr session name | `default` | The session that owns the new tab |
| `--workspace <id>` | workspace id such as `w2` | the focused workspace | Which workspace the tab joins |
| `--cwd <path>` | absolute path on that host | the herdr default | Working directory for the shell |
| `--label <text>` | free text | the tab number | The name Herdr and Edith show for the tab |
| `--json` | flag | off | Emit JSON on stdout |

The tab is created without stealing focus, so an attached Herdr client stays
where it was. The shell belongs to the Herdr server on that host, which means it
outlives Edith and appears in `ed herdr ls`, in the Herdr page and in the Herdr
client itself.

## `--json` shape

```json
{
  "label": "site dev server",
  "machine": "Asus TUF 7",
  "pane": "w2:p7",
  "session": "default"
}
```

`label` is `null` when no label was given. The human form prints the machine,
the session and the new pane separated by spaces.

## Exit codes

| Code | When |
| --- | --- |
| 0 | The terminal was created |
| 2 | The command line was wrong |
| 3 | `--machine` named no configured machine |
| 4 | Herdr refused the request, or the host could not be reached |

## Notes and gotchas

- `--cwd` is evaluated on the far host, so pass a path that exists there. A
  missing directory is Herdr's error, not Edith's.
- Terminals are attached with the Herdr client rather than a single pane
  attach: `herdr --session <name>` locally and `herdr --remote <target>
  --session <name>` for another machine. `ed herdr command` prints the line.
- The new pane may take a moment to appear in `ed herdr ls` while the Herdr
  server publishes it.

## Where to go next

- [`ed herdr ls`](./ls.md), the panes that already exist
- [`ed herdr`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
