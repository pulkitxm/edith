# `ed usage statusline`

Connects Claude Code's status line to Edith, which is where Edith gets Claude's
5-hour and 7-day rate limits.

Claude Code runs the command named in the `statusLine` setting of its
`settings.json` and passes it a JSON document on standard input. For claude.ai
Pro and Max subscribers that document carries `rate_limits.five_hour` and
`rate_limits.seven_day`, each with `used_percentage` and `resets_at`, after the
first response of a session. `ed usage statusline install` points that setting
at `ed usage statusline record`, which writes those two windows to
`limits-history.jsonl` and prints a short line such as `5h 42% · 7d 18%`. The
background agent reads the newest Claude row on every limits poll, so Edith
never asks Anthropic for Claude usage itself.

The numbers are as fresh as your last Claude Code response. A window whose
`resets_at` has passed is dropped until Claude Code reports it again, the same
way Claude Code treats it. Usage from other Claude apps counts towards the same
limits but only shows up after Claude Code's next response.

Any custom status line, this one included, replaces most of the keyboard hints
in Claude Code's footer. When `statusLine` already names a command, `install`
keeps it: Edith records the limits, runs your command with the same input and
prints its output instead of Edith's line.

While the Claude limits setting is on, the background agent connects the status
line for you. Each limits poll checks `settings.json` and runs the same install as
`ed usage statusline install`, which also repairs a command that points at a
moved or wrong Edith. It does nothing when Claude Code has no settings folder yet,
when the file does not parse, or in a development build. `ed usage statusline
remove`, or Disconnect in Settings, turns the automatic connection off until you
run `install` or press Connect again. The command written into Claude Code's
settings is the `ed` launcher inside the app, so Claude Code never starts the app
window.

The settings file is `$CLAUDE_CONFIG_DIR/settings.json` when that variable is
set and `~/.claude/settings.json` otherwise. Edith rewrites it as sorted,
indented JSON, writes through a symbolic link to the file it points at, and
never touches a file that does not parse as a JSON object.

`ed usage statusline` on its own runs `status`.

## `ed usage statusline status`

Shows whether Claude Code's status line feeds Edith.

```
ed usage statusline status [--settings <path>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--settings` | path | Claude Code's settings file | Read this settings file instead |
| `--json` | flag | off | Emit JSON on stdout |

`wraps` is the command that runs after Edith's, or `null`. `recordedAt` is the
newest Claude row in `limits-history.jsonl`, or `null`.

```json
{
  "installed": true,
  "recordedAt": "2026-10-03T08:40:12Z",
  "settings": "/Users/you/.claude/settings.json",
  "wraps": null
}
```

## `ed usage statusline install`

Installs Edith as Claude Code's status line command and turns the automatic
connection back on.

```
ed usage statusline install [--settings <path>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--settings` | path | Claude Code's settings file | Change this settings file instead |
| `--json` | flag | off | Emit JSON on stdout |

`change` is `installed`, `wrapped` when an existing command now runs after
Edith's, or `unchanged` when it was already in place.

```json
{
  "change": "installed",
  "settings": "/Users/you/.claude/settings.json"
}
```

## `ed usage statusline remove`

Removes Edith from Claude Code's status line and stops the agent from connecting
it again.

```
ed usage statusline remove [--settings <path>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--settings` | path | Claude Code's settings file | Change this settings file instead |
| `--json` | flag | off | Emit JSON on stdout |

`change` is `removed` when the `statusLine` setting is deleted, `restored` when
the command Edith wrapped is put back, or `absent` when Edith's command was not
there, in which case the file is left alone.

## `ed usage statusline record`

Saves the windows Claude Code passes to its status line. Claude Code runs this
command; you only run it by hand to test the feed.

```
ed usage statusline record [--input <path>] [--then <command>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--input` | path | standard input | Read the status line JSON from this file |
| `--then` | shell command | none | Run this command with the same input and print its output instead |
| `--json` | flag | off | Emit JSON on stdout |

Input without `rate_limits` records nothing and prints nothing, which is what
Claude Code sends before a session's first response or for an account without a
subscription.

```json
{
  "line": "5h 42% · 7d 18%",
  "recorded": true,
  "session": {
    "percent": 42,
    "resetsAt": "2026-10-03T11:50:00Z",
    "resetsInSeconds": 9000
  },
  "week": {
    "percent": 18,
    "resetsAt": "2026-10-08T08:00:00Z",
    "resetsInSeconds": 418200
  }
}
```

## Exit codes

| Code | When |
| --- | --- |
| 0 | The status was read, the settings changed or were already right, or the input was read |
| 1 | The settings file is not a JSON object, or could not be written |
| 2 | `--then` combined with `--json` |
| 3 | No file at the `--input` path |

## Examples

```
ed usage statusline status
ed usage statusline install
ed usage statusline record --input status.json --json
ed usage statusline remove
```

## Where to go next

- [`ed usage limits`](./limits.md), which shows what was recorded
- [`ed usage`](../README.md), the rest of this group
