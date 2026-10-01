# `ed skills`

`ed skills` is the Edith skill library as a command: the three skills that ship
with the app, the Markdown behind each one, and the install the Plugins page
runs into the agents already on this Mac.

`ls` only reads the bundled catalog and which agent directories exist here.
`preview` and `copy` download `SKILL.md` from GitHub and fall back to
`~/Library/Application Support/Edith/plugins/cache` when that fetch fails.
`install` is the install sheet: it previews the skill and agents, then with
`--yes` runs the same `npx skills` installer the app uses. `ed skills` with
nothing after it is `ed skills ls`.

## At a glance

| Command | What it does |
| --- | --- |
| `ed skills` | Runs `ed skills ls`. |
| `ed skills ls` | Lists library skills and detected agents. |
| `ed skills preview <id>` | Prints the skill body. |
| `ed skills copy <id>` | Prints the complete Markdown, or copies it with `--clipboard`. |
| `ed skills install <id>` | Previews an install, or writes the skill with `--yes`. |

`ed skills list` is the same command as `ed skills ls`.

## Commands

- [`ed skills ls`](./ls.md)
- [`ed skills preview`](./preview.md)
- [`ed skills copy`](./copy.md)
- [`ed skills install`](./install.md)

## Exit codes

| Code | When this group produces it |
| --- | --- |
| 0 | The listing printed, the document loaded, the clipboard was set, or the install plan was printed or applied. |
| 1 | GitHub and the cache both failed, the clipboard rejected the copy, or the installer failed. |
| 2 | `--agent` was omitted and no detected agent is selected, or an agent id is not in the catalog. |
| 3 | The skill id is not in the Edith library. |

## Notes

- Agent ids are the ones the install sheet already knows, such as `cursor` and
  `claude-code`. `ed skills ls --json` prints the ones detected on this Mac.
  `--all-agents` prints the full catalog.
- Install without `--agent` uses detected agents whose saved selection is on,
  which is the sheet's default.
- Passing `--yes` is what writes files. A preview does not call `npx`.

## See also

- [`ed skills ls`](./ls.md)
- [`ed`](../README.md)
