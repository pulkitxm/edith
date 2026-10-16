# `ed agent schedule`

Runs commands on a schedule inside the daemon, so recurring work keeps going with
no window open and no terminal attached. `ed agent schedule` defaults to
`ed agent schedule ls`.

```text
ed agent schedule ls [--json]
ed agent schedule add <name> (--every <interval> | --cron "<expression>") [--cwd <path>] [--timeout 300] [--json] -- /absolute/executable [arguments...]
ed agent schedule rm <name>
ed agent schedule enable <name> [--json]
ed agent schedule disable <name> [--json]
ed agent schedule run <name> [--json]
```

A schedule is a name, a timing rule and a command. The daemon saves it in its
store, so it survives restarts, updates and reboots. When a run is due, the daemon
submits the command to its bounded task queue, the same queue behind
[`ed agent tasks exec`](./tasks.md). Every run is an ordinary task: follow it with
`ed agent tasks ls` and `ed agent tasks inspect <id>`, cancel it with
`ed agent tasks cancel <id>`.

## Timing

`--every` takes a whole number and a unit: `s`, `m`, `h` or `d`, such as `90s`,
`15m`, `6h` or `1d`. Intervals run from 1 minute to 7 days. `--cron` takes a
five-field expression in the Mac's local time zone:

```text
minute  hour  day-of-month  month  weekday
0-59    0-23  1-31          1-12   0-7 (0 and 7 are Sunday)
```

Each field accepts `*`, a number, a range (`1-5`), a list (`1,15`), and steps
(`*/10`, `0-30/5`). When both day-of-month and weekday are restricted, a run
fires when either matches, as in classic cron. Names such as `mon` or `jan` are
not supported. An expression that can never fire, like `0 0 31 2 *`, is refused.

## What the daemon guarantees

- A run missed while the daemon was stopped, or the Mac was asleep for the whole
  window, is skipped. The next run is planned from the moment the daemon starts.
- A run is skipped when the previous run of the same schedule is still queued or
  running, so a slow command never piles up.
- Each run is bounded by `--timeout`, up to 7200 seconds, and its output is capped.
  A command that overruns has its whole process group stopped.
- A run starts in `--cwd`, which defaults to the directory where you ran `add`, with
  the login shell environment the daemon captured. The environment is not stored.
- The daemon keeps at most 64 schedules. Retained task results follow the normal
  task limits, so a very frequent schedule does not grow the store.
- `ed agent schedule run` queues one run immediately and does not move the next
  planned run. It is refused while the previous run is still going.
- `disable` stops new runs and leaves a run already going to finish. `rm` deletes
  the schedule the same way.

Schedules are for commands you trust: they run as you, unattended. The command line
is stored in the daemon's database without encryption, so keep secrets out of the
arguments and let the command read them from the Keychain or a file.

```sh
ed agent schedule add sync --every 15m -- /usr/bin/true
ed agent schedule add nightly --cron "30 2 * * *" --timeout 3600 -- /usr/bin/true
ed agent schedule ls --json
ed agent schedule run sync
ed agent schedule disable nightly
```

- [`ed agent tasks`](./tasks.md), inspect and cancel the runs
- [`ed agent`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
