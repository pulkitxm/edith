# `ed herdr defaults`

The model, effort and fast mode Edith passes whenever it starts an agent of a
given kind. The Agent Launch Settings sheet on the Herdr page edits the same
values.

```
ed herdr defaults [ls] [--json]
ed herdr defaults set <kind> [--model <id>] [--effort <level>] [--fast on|off] [--json]
```

`ed herdr defaults` runs `ed herdr defaults ls`. `list` is an alias for `ls`.

## `set` arguments and options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<kind>` | `claude`, `codex`, `cursor`, `pi`, `gemini`, `amp`, or the display name | required | The agent kind to change |
| `--model <id>` | a model id or alias from `ed herdr models`, or `none` | unchanged | The model; `none` lets the CLI choose |
| `--effort <level>` | an effort level the model supports, or `none` | unchanged | Effort for Claude Code and Codex, thinking level for Pi |
| `--fast on\|off` | `on`, `off` | unchanged | Fast mode, only for models that offer it |
| `--json` | flag | off | Emit JSON on stdout |

At least one of `--model`, `--effort` or `--fast` is required. Values are
checked against the model list on this Mac: an effort the model does not
support, fast mode on a model without it, an Amp mode that does not exist, or
any option for OpenCode exits 2 and stores nothing. A model id that is not in
the list is accepted for every kind except Amp, and is checked against the
default model's effort levels.

## What a launch does with them

When the stored launch command is the default, Edith runs
`herdr agent start <name> --kind <kind> --pane <pane> -- <flags>`. When the
command was edited on the sheet, the same flags are appended to the typed
command. Flags a model cannot take are dropped at launch rather than failing it.

| Kind | Flags |
| --- | --- |
| Claude Code | `--model <id> --effort <level> --settings '{"fastMode":true}'` |
| Codex | `-m <id> -c model_reasoning_effort="<level>" -c service_tier="fast"` |
| Pi | `--model <id> --thinking <level>` |
| Cursor Agent | `--model <id>` |
| Gemini | `-m <id>` |
| Amp | `--mode <mode>` |

## `--json` shape

`ls` prints `{"defaults": [...]}` with one entry per kind. `set` prints the one
entry it saved.

```json
{
  "arguments": ["-m", "gpt-6-sol", "-c", "model_reasoning_effort=\"high\"", "-c", "service_tier=\"fast\""],
  "effort": "high",
  "fast": true,
  "kind": "Codex",
  "model": "gpt-6-sol"
}
```

The human `ls` form is a table, `KIND`, `MODEL`, `EFFORT`, `FAST`, `FLAGS`. An
unknown kind exits 3.

The values live in the `herdrLaunchDefaults` setting, which `ed config get`
shows and settings backups carry.

## Where to go next

- [`ed herdr models`](./models.md), what each kind offers
- [`ed herdr`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
