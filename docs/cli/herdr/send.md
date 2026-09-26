# `ed herdr send`

Types a message into a live agent and presses Return, through
`herdr agent prompt`. The target is one pane, or every working or every
stopped agent at once. With `--when-finished` the message waits until that
agent finishes its current turn instead.

```
ed herdr send <pane> <message> [--machine <name>] [--session <name>] [--when-finished] [--json]
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
| `--json` | flag | off | Emit JSON on stdout |

## What Herdr accepts

Herdr refuses to type into an agent that is `blocked`, because it is waiting on
an approval or a question and extra input would answer it. Those agents are
reported as skipped, never retried. An agent that is no longer the pane's
foreground process is skipped too. Terminals are never messaged.

A working agent does receive the text. Most agents queue it for after the
current turn. `submitted` means Herdr typed it, not that the agent acted on it.

## `--when-finished`

The background agent keeps the message and checks the agent with
`herdr agent get` every two seconds on this Mac and every ten seconds on SSH
machines. It sends the message once the agent has worked and is back at its
prompt, then keeps the result for a day so `ed herdr hooks` and the Herdr page
can show it. It is sent at most once: if Edith restarts in the middle of
sending, it is not sent again. A new message for the same agent replaces the
waiting one. The message is dropped when the agent closes or a different kind
of agent takes over the pane.

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
`--when-finished` prints the waiting hook in the shape `ed herdr hooks` uses.

The human form for a group is a table, `MACHINE`, `PANE`, `TITLE`, `RESULT`. An
empty group prints a note on stderr and exits 0.

## Exit codes

| Code | When |
| --- | --- |
| 0 | Submitted to the pane, the group ran, or the hook is waiting |
| 1 | One pane was named and Herdr did not take the message |
| 2 | Empty message, `--when-finished` with a group, or a terminal pane |
| 3 | No such pane, or `--machine` named no configured machine |
| 4 | `--when-finished` and the background agent is not running |

## Where to go next

- [`ed herdr hooks`](./hooks.md), waiting messages and their results
- [`ed herdr`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
