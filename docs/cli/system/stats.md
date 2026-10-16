# `ed system stats`

Takes one sample of this Mac and prints it, or keeps sampling with `--follow`.
It is the default subcommand, so `ed system` on its own runs it.

```
ed system stats [--json] [--follow] [--interval <seconds>] [--processes <n>]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the human lines. Long form only, there is no `-j`. |
| `--follow`, `-f` | flag | off | Keep sampling until interrupted. Also switches `--json` from one pretty document to one compact document per line. |
| `--interval` | seconds, greater than 0 | `2` | Seconds between samples when following. Ignored without `--follow`, and clamped up to a floor of `0.5`. |
| `--processes` | integer, 0 or more | `0` | Include this many top processes by CPU in each sample. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

Without `--follow` the command prints one sample and exits. The first line is a
header carrying the host name, the OS string and the core count; the second is
the sample itself:

```
$ ed system stats
Studio MacBook Pro  macOS Version 26.5.2 (Build 25F84)  14 cores
cpu  53.3%   mem 73% of 25.8 GB   load 16.54 19.29 17.56   net down 36.6 KB/s up 9.1 KB/s
```

`--processes n` appends a table of the top `n` processes by CPU under the
sample, the same rows the app's Processes tab shows for this Mac:

```
$ ed system stats --processes 5
Studio MacBook Pro  macOS Version 26.5.2 (Build 25F84)  14 cores
cpu  45.3%   mem 72% of 25.8 GB   load 16.54 19.29 17.56   net down 26.0 KB/s up 4.9 KB/s
PID    USER           CPU    MEM  NAME
20520  pulkit         195.1  0.0  turbo
405    _windowserver  32.3   0.3  WindowServer
36852  pulkit         21.6   1.7  Browser Helper (Renderer)
25053  pulkit         20.8   2.0  2.1.226
54438  pulkit         19.6   7.7  com.apple.Virtualization.VirtualMachine
```

With `--follow` the header prints once and each later sample adds one line. The
process table, if you asked for one, is reprinted under every sample rather than
once:

```
$ ed system stats --follow --interval 0.5
Studio MacBook Pro  macOS Version 26.5.2 (Build 25F84)  14 cores
cpu  61.5%   mem 74% of 25.8 GB   load 17.81 19.27 17.67   net down 39.2 KB/s up 85.0 KB/s
cpu  60.9%   mem 74% of 25.8 GB   load 17.81 19.27 17.67   net down 43.8 KB/s up 24.8 KB/s
cpu  65.0%   mem 74% of 25.8 GB   load 17.81 19.27 17.67   net down 49.4 KB/s up 20.9 KB/s
```

## `--json` shape

One object with a `host` half that never changes and a `sample` half that does.
This is a real document, trimmed to one process, one network interface and
three of the fourteen `corePercent` entries:

```json
{
  "host": {
    "arch": "arm64",
    "cores": 14,
    "cpuModel": "Apple M4 Pro",
    "host": "Studio MacBook Pro",
    "kernel": "25.5.0",
    "memTotalKB": 25165824,
    "os": "macOS Version 26.5.2 (Build 25F84)",
    "osID": "macos",
    "virtual": false
  },
  "sample": {
    "at": "2026-08-08T16:37:59Z",
    "cpu": {
      "corePercent": [
        46.42857142857143,
        39.285714285714285,
        29.09090909090909
      ],
      "stealPercent": 0,
      "totalPercent": 52.78934221482098
    },
    "disk": {
      "devices": [],
      "readBps": 0,
      "writeBps": 0
    },
    "intervalSeconds": 0.5604119300842285,
    "load": [
      15.4755859375,
      18.97265625,
      17.46337890625
    ],
    "memory": {
      "availableKB": 6707072,
      "buffCacheKB": 5027472,
      "swapTotalKB": 5242880,
      "swapUsedKB": 3656192,
      "totalKB": 25165824,
      "usedKB": 18458752,
      "usedPercent": 73.34849039713541
    },
    "network": {
      "interfaces": [
        {
          "name": "en0",
          "rxBps": 58471.274862180486,
          "txBps": 436707.33412691054,
          "virtual": false
        }
      ],
      "rxBps": 58471.274862180486,
      "txBps": 436707.33412691054
    },
    "processes": [
      {
        "command": "/opt/homebrew/bin/turbo",
        "cpuPercent": 196.5,
        "memPercent": 0,
        "name": "turbo",
        "pid": 20520,
        "rssKB": 7312,
        "user": "pulkit"
      }
    ],
    "tasks": {
      "runnable": 0,
      "total": 566
    },
    "uptimeSeconds": 97895.422400625
  }
}
```

What the fields mean:

- `host.os` is built as the word `macOS` followed by the version string macOS
  itself reports, which is why it reads `macOS Version 26.5.2 (Build 25F84)`.
  `host.osID` is always `macos` here, and `host.virtual` is always `false`.
- `host.host` is the computer's Sharing name, falling back to `kern.hostname`.
  `host.kernel` is `kern.osrelease`, `host.arch` is `hw.machine`, and
  `host.cpuModel` is `machdep.cpu.brand_string`.
- `sample.at` is the sample time as `2026-08-08T16:37:59Z`, and
  `sample.intervalSeconds` is how long the window behind this sample actually
  was, which is close to but not exactly `--interval`.
- `cpu.totalPercent` is 0 to 100 across the whole machine, and `cpu.corePercent`
  has one entry per logical core in core order.
- Every `*KB` number is kilobytes and every `*Bps` number is bytes per second.
  `memory.usedPercent` is `usedKB` over `totalKB`.
- `load` is the one, five and fifteen minute load averages, in that order.
- `processes` is present even when it is empty, so the key never disappears
  between runs.

## Examples

```
ed system stats
ed system stats --json
ed system stats --processes 10
ed system stats --follow --interval 5 --json | jq -c '{at: .sample.at, cpu: .sample.cpu.totalPercent}'
```

## Behaviour notes

Nothing is mutated and nothing is written: the command samples and prints.
Neither the Edith app nor the menu bar helper has to be running, and no macOS
permission is involved, so this never exits 4.

The first sample costs about half a second. `ed` takes a throwaway sample,
sleeps 500 ms, then takes the one it prints, because CPU and network figures are
deltas between two readings and the first reading has nothing to compare
against. That is also why `intervalSeconds` on the first line of a `--follow`
run reads around `0.56` rather than your `--interval`.

`--interval` is validated as greater than zero and finite, so `--interval 0`,
a negative value and `--interval nan` all exit 2 before any sampling happens.
`--processes` is validated as zero or more and exits 2 when negative, though
you have to write `--processes=-1` to get there: `--processes -1` is read as a
missing value by the parser and exits 2 for that reason instead.

```
$ ed system stats --interval 0
error: --interval must be greater than zero

$ ed system stats --processes=-1
error: --processes cannot be negative
hint: pass 0 or more
```

Interrupting a `--follow` run with Ctrl-C is the normal way to stop it. There is
no sample count option and no timeout.

## Where to go next

- [`ed system`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
