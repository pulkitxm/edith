# `ed system`

`ed system` reports on the Mac you are typing on: a live CPU, memory, load and
network sample, and the volumes that are mounted. It reads the machine directly
through `sysctl`, the Mach host statistics, `/bin/ps` and `pmset`, so nothing
here talks to the Edith app and nothing here needs it running. Reach for it when
you want the numbers the app's This Mac view shows without opening a window, or
when you want them on stdout as JSON.

It is the local half of a pair. `ed machines metrics <machine>` is the same
report for a machine over SSH, in the same shape, so a script can treat both the
same way.

## At a glance

| Command | What it does |
| --- | --- |
| `ed system stats` | Samples CPU, memory, load, uptime, network and optionally the top processes. Streams with `--follow`. Runs when you type `ed system` with no subcommand. |
| `ed system disks` | Lists the mounted volumes with their size, free space and use, plus battery, temperature and GPU fields in JSON. |

## Commands

## Commands

- [`ed system stats`](./stats.md)
- [`ed system disks`](./disks.md)

## Exit codes

| Code | When |
| --- | --- |
| 0 | The sample or the volume list was printed. `--help` and `--version` also exit 0. |
| 2 | `--interval` was zero, negative or not finite; `--processes` was negative; or the command line was wrong in the ordinary way, an unknown flag, a missing value, or a value that is not a number. |

Neither command looks anything up by name and neither talks to the app, so 3 and
4 cannot happen here. Code 1 is the catch-all for an unexpected error escaping
`ed system stats`, and nothing on the local sampling path throws one.

## Notes and gotchas

- `ed system` with no subcommand is `ed system stats`. `stats` is declared as
  the group's default subcommand, so the two are the same invocation.
- Sizes are formatted with decimal units. `KB` is 1000 bytes, `MB` is 1000 KB,
  and so on, which is why a volume of 482797652 KB prints as `494 GB` rather
  than `460 GB` and 25165824 KB of memory prints as `25.8 GB`. The JSON is raw
  kilobytes, so do your own maths there if you want binary units.
- At most 30 processes exist to be reported. The sampler keeps the top 30 by
  CPU, so `--processes 50` gives you 30 rows and no warning.
- `cpuPercent` in the process rows comes from `ps` and is summed across cores,
  so a busy process reads above 100. `cpu.totalPercent` for the machine is
  capped at 100 across all cores. The two are not on the same scale.
- The process list is `/bin/ps -axo pid=,user=,%cpu=,%mem=,rss=,comm=` sorted by
  CPU descending, and `name` is the last path component of `command`.
- Network counters skip `lo0` entirely, and an interface that moved no bytes
  during the window is left out of `interfaces` rather than listed at zero. The
  `rxBps` and `txBps` totals exclude interfaces judged virtual, which is
  anything named `utun*`, `awdl*`, `llw*`, `bridge*`, `ap*`, `gif*`, `stf*` or
  `anpi*`; those interfaces still appear in the list, with `virtual: true`.
- `disk.readBps`, `disk.writeBps` and `disk.devices`, along with
  `cpu.stealPercent` and `tasks.runnable`, are part of the shared sample shape
  and are always zero or empty for this Mac. They are filled in by the collector
  `ed machines metrics` runs on a Linux machine.
- `tasks.total` is the number of processes `ps` returned, so it counts every
  process on the machine and not just the ones `--processes` shows.
- `--json --follow` writes one compact document per line, forever, and repeats
  the whole `host` object on every line. That is deliberate: each line stands
  alone, so `jq -c`, `head` and a pipe into another process all work without
  buffering a document that never ends. Without `--follow` you get a single
  pretty-printed document instead.
- Object keys are sorted, in both the pretty and the compact form, so two runs
  diff cleanly.
- `stats` is the same `LocalMachineSampler` the app drives for its This Mac
  session, so the CLI and the window cannot disagree about a number. The window
  samples every two seconds and refreshes its volume and battery half on every
  fifteenth tick, about every thirty seconds; `ed system disks` reads it fresh
  on every call.
- The `systemStats` extension, the CPU and memory readout in the menu bar, is
  unrelated to these commands. `ed system` never consults it, and both commands
  work with every extension turned off.

## Where to go next

- [`ed machines`](../machines/README.md) for the same sample taken on another machine
  over SSH, including the disk, steal and task fields this page reports as zero.
- [`ed cleaner`](../cleaner/README.md) for acting on what `ed system disks` tells you
  about free space.
- [`ed extensions`](../extensions/README.md) for the menu bar CPU and memory readout.
- [The `ed` command line](../README.md) for the rest of the reference.
