# `ed usage refresh`

Re-collects usage data from every agent, on this Mac and on the machines, and
rewrites `usage.json`.

```
ed usage refresh [--follow] [--machines | --no-machines] [--json]
```

Machines counted towards usage are topped up first, but only the stale ones:
a machine collected within the last half hour is left alone, so a refresh on a
loop does not open an SSH connection every time. `--machines` collects from all
of them regardless of when they were last seen, `--no-machines` skips them and
merges whatever is already on disk. `--follow` never collects, since it is
watching a run that someone else started.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--follow` | flag | off | Attach to a refresh that is already running instead of starting one, and fail when there is nothing to watch |
| `--machines` | flag | off | Force every counted machine to collect first; fail before the local pipeline if any machine is busy or fails |
| `--no-machines` | flag | off | Skip machine collection and merge the machine snapshots already on disk |
| `--json` | flag | off | Emit JSON on stdout |

## `--json` shape

```json
{
  "completed": true,
  "followed": false,
  "phases": [
    {
      "detail": "cached",
      "name": "ccusage",
      "seconds": 0.01
    },
    {
      "detail": "27 days",
      "name": "cli",
      "seconds": 1.47
    },
    {
      "detail": "125311 messages",
      "name": "walk",
      "seconds": 3
    }
  ],
  "seconds": 9.98,
  "summary": {
    "machines": "Asus TUF 7",
    "sources": "cli, codex, commandcode, machine:0b481f65-f946-4636-ab36-e4508eb67e6a:cli",
    "spend": "$10876.85 · 378 sessions · 401 KB",
    "window": "2026-07-08 to 2026-08-08 · 27 days · 7 models"
  }
}
```

`completed` is always `true`: reaching the JSON at all means the pipeline
finished, because every other outcome is an error. `followed` says whether this
invocation watched a run someone else had started instead of starting its own.
`seconds` is the pipeline's own total, `phases` carries every phase row in the
order they landed, three of the eight above, and `summary` is the closing block
keyed by label.

## Examples

```
ed usage refresh
ed usage refresh --follow
ed usage refresh --json | jq -r '.summary.spend'
ed usage refresh && ed usage summary --range today
```

## Behaviour

This is the only verb in the group that changes anything, and `ed` does the work
itself. It runs the same collection pipeline EdithKit hands the app, in this
process, so it needs no menu bar app and there is nothing to time out on. A
first run takes noticeably longer, because the collector installs `ccusage`, and
`jq` or `bun` when they are missing, before it can read anything.

Progress goes to stderr and stdout stays clean: one `usage refreshed` line at
the end, or the JSON object. Each phase is printed as it lands, with a spinner on
the phase in flight, and the whole display is skipped when `--json` is passed or
stderr is not a terminal, so a pipe sees nothing extra. `NO_COLOR` and
`TERM=dumb` switch it off too, rather than only dropping the colour.

A run holds a lock on `refresh.lock` in the data directory, so two of them
cannot clobber `usage.json`. When one is already running, in the app or in
another terminal, `ed` attaches to it instead of starting a second, printing `a
refresh is already running, attaching to it` and reporting that run's phases as
they land. `--follow` asks for that explicitly, and that is the difference
between the two: with nothing running it exits 4 with `no usage refresh is
running`, hinted `drop --follow to start one`, where a plain `ed usage refresh`
would have started one.

A pipeline failure is an error rather than a quiet success. What the collector
reported becomes the message, exit 4, hinted at `data/refresh.log`, which is
where the same transcript is written line by line while the run happens. A run
that was attached to and then stopped without finishing fails the same way.

The default stale-machine top-up is best effort. A machine that is offline,
busy, or fails collection does not prevent this Mac from refreshing and merging
the last snapshot on disk. `--machines` is strict instead: it forces every
counted machine regardless of freshness, and any busy or failed machine exits 4
before the local pipeline starts. Passing both machine flags is invalid.

```
$ ed usage refresh

  EDITH · refresh usage · 2026-08-08 23:57:31
  ────────────────────────────────────────────────────
  ▸ ccusage    cached                             0.01s
  · discovering sources
  ▸ cli        27 days                            1.47s
  ▸ codex      12 days                            0.83s
  ▸ commandcode 1 days                             0.85s
  · assembling usage.json
  · walking 900 transcript files
  ▸ walk       125311 messages                    3.00s
  ▸ projects   174 repos                          2.35s
  ▸ merge      hours + projects merged            1.32s
  ▸ machines   1 folded in                        0.05s
  ────────────────────────────────────────────────────
  ✓ sources   cli, codex, commandcode, machine:0b481f65-f946-4636-ab36-e4508eb67e6a:cli
  ✓ machines  Asus TUF 7
  ✓ window    2026-07-08 to 2026-08-08 · 27 days · 7 models
  ✓ spend     $10876.85 · 378 sessions · 401 KB
  ✓ done in 9.98s

usage refreshed
```

## Where to go next

- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
