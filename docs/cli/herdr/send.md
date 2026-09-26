# `ed herdr send`

Types a message into a live agent and presses Return, through
`herdr agent prompt`. The target is one pane, or every working or every
stopped agent at once. One pane can wait until the agent finishes, until a
delay elapses, or until a clock time.

```
ed herdr send <pane> <message> [--machine <name>] [--session <name>] [--when-finished] [--in <delay>] [--at <time>] [--json]
ed herdr send working|stopped <message> [--machine <name>] [--session <name>] [--json]
```

## Arguments and options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<pane>` | a pane id such as `w3:p1N`, or `working`, or `stopped` | required | One agent, every agent in the middle of a turn, or every idle and finished agent |
| `<message>` | text | required | What to type; leading and trailing whitespace is trimmed |
| `--machine <name>` | machine name, alias, UUID, unique prefix, or `local` | all hosts | Only this Mac, or only one SSH machine |
| `--session <name>` | Herdr session name | any | Narrow a pane id, or a group, to one session |
| `--when-finished` | flag | off | Hand the message to the background agent, which sends it once the agent next finishes |
| `--in <delay>` | `15m`, `90m`, `1h`, or `1h30m` | unset | Send once after this delay. Up to 7 days |
| `--at <time>` | `16:30`, `4:30pm`, `4pm`, or `tomorrow 9:00am` | unset | Send once at this future clock time. Bare times are 24-hour |
| `--json` | flag | off | Emit JSON on stdout |

## What Herdr accepts

Herdr refuses to type into an agent that is `blocked`, because it is waiting on
an approval or a question and extra input would answer it. Those agents are
reported as skipped, never retried. An agent that is no longer the pane's
foreground process is skipped too. Terminals are never messaged.

A working agent does receive the text. Most agents queue it for after the
current turn. `submitted` means Herdr typed it, not that the agent acted on it.

## `--when-finished`, `--in`, and `--at`

Pick at most one. A group (`working` or `stopped`) always sends now.

The background agent keeps the message. `--when-finished` checks the agent
with `herdr agent get` every two seconds on this Mac and every ten seconds on
SSH machines, and sends once the agent has worked and is back at its prompt.
`--in` and `--at` send at that moment even if the agent is mid-turn. Herdr
then queues the text or skips it, and the result is kept for a day so
`ed herdr hooks` and the Herdr page can show it. It is sent at most once: if
Edith restarts in the middle of sending, it is not sent again. A new message
for the same agent replaces the waiting one. The message is dropped when the
agent closes or a different agent takes over the pane.

Polling can miss a turn that starts and ends between two checks while the pane
is focused in Herdr, because Herdr then reports `idle` instead of `done`.

## `--json` shape

Sending now prints the per-agent results.

```json
{
  "executed": true,
  "failures": ["w1:p2: Skipped: waiting for your input"],
  "results": [
    {
      "detail": "Skipped: waiting for your input",
      "id": "local|default|w1:p2",
      "machineName": "This Mac",
      "pane": "w1:p2",
      "result": "blocked",
      "session": "default",
      "title": "Refactor the parser"
    }
  ],
  "submitted": 0
}
```

`result` is one of `submitted`, `blocked`, `not_ready`, `gone`, `failed`.
`failures` lists every pane that did not take the message.
`--when-finished`, `--in`, and `--at` print the waiting hook in the shape `ed herdr hooks` uses.

The human form for a group is a table, `MACHINE`, `PANE`, `TITLE`, `RESULT`. An
empty group prints a note on stderr and exits 0.

## Exit codes

| Code | When |
| --- | --- |
| 0 | Submitted to the pane, the group ran, or the hook is waiting |
| 1 | One pane was named and Herdr did not take the message |
| 2 | Empty message, a scheduled group, more than one delivery flag, a delay or time Edith cannot read, or a terminal pane |
| 3 | No such pane, or `--machine` named no configured machine |
| 4 | A scheduled send and the background agent is not running |

## Where to go next

- [`ed herdr hooks`](./hooks.md), waiting messages and their results
- [`ed herdr`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
