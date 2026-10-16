# `ed skills install`

Installs one Edith skill into the agents you name.

[`ed skills`](./README.md)

Usage:

```
ed skills install <id> [--agent <id> ...] [--yes] [--json]
```

Arguments:

| Name | What it is |
| --- | --- |
| `<id>` | A skill id from `ed skills ls`. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--agent` | agent id, repeatable | detected selections | Agent to install into. Repeat the flag to add more. |
| `--yes` | flag | off | Applies the plan. Without it, nothing is written. |
| `--json` | flag | off | Emits the plan, or the result, as JSON. |

Without `--agent`, the command uses detected agents whose saved install-sheet
selection is on. The preview names the skill and those agents. `--yes` runs
`npx --yes skills@1.5.24 add` the same way the install sheet does, then checks
that each agent received the skill.

`--json` preview:

```json
{
  "action": "install edith-remote-work",
  "applied": false,
  "changed": false,
  "targets": ["cursor"]
}
```

Examples:

```
ed skills install edith-remote-work --agent cursor
ed skills install edith-remote-work --agent cursor --yes
ed skills install edith-video-delivery --json
```

See also:

- [`ed skills ls`](./ls.md)
- [`ed skills`](./README.md)
- [`ed`](../README.md)
