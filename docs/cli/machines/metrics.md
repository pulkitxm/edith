# `ed machines metrics`

Samples a machine, once or continuously. It is the same collector the app's
Machines view drives, fed to the machine on stdin, so nothing is installed
there and nothing is left behind.

```
ed machines metrics <machine> [--json] [--follow] [--interval <seconds>]
                              [--processes <n>]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the human lines. |
| `--follow`, `-f` | flag | off | Keep streaming until interrupted. Also switches `--json` from one pretty document to one compact document per line. |
| `--interval` | integer seconds, greater than 0 | `2` | Seconds between samples when following. Ignored without `--follow`. |
| `--processes` | integer, 0 or more | `0` | Include this many of the processes each sample carries, out of the thirty at most that the collector sends. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

The first line is the collector's greeting, carrying the machine's own host
name, its OS string and its core count. Each later line is a sample:

```
$ ed machines metrics tuf
pulkit-tuf  Ubuntu 24.04.4 LTS  20 cores
cpu   1.0%   mem 5% of 67.0 GB   load 0.12 0.14 0.30   net down 132 B/s up 1.6 KB/s
```

Without `--follow` it prints exactly one sample and exits. With `--follow` the
greeting prints once and a sample line is added every `--interval` seconds until
you interrupt it.

## `--json` shape

One object with a `host` half that never changes and a `sample` half that does.
This is a real document with the core list, the device list and the process list
trimmed:

```json
{
  "host": {
    "arch": "x86_64",
    "cores": 20,
    "cpuModel": "12th Gen Intel(R) Core(TM) i7-12700H",
    "host": "pulkit-tuf",
    "kernel": "7.0.0-28-generic",
    "memTotalKB": 65452140,
    "os": "Ubuntu 24.04.4 LTS",
    "osID": "ubuntu",
    "virtual": false
  },
  "sample": {
    "at": "2026-08-08T16:48:25Z",
    "cpu": {
      "corePercent": [0, 0, 1.8, 0, 2.7],
      "stealPercent": 0,
      "totalPercent": 0.9
    },
    "disk": {
      "devices": [
        {
          "busyPercent": 0,
          "name": "nvme0n1",
          "readBps": 0,
          "writeBps": 24576
        }
      ],
      "readBps": 0,
      "writeBps": 24576
    },
    "intervalSeconds": 1,
    "load": [0.12, 0.14, 0.3],
    "memory": {
      "availableKB": 62045152,
      "buffCacheKB": 56620508,
      "swapTotalKB": 8388604,
      "swapUsedKB": 376,
      "totalKB": 65452140,
      "usedKB": 3406988,
      "usedPercent": 5.205311850766072
    },
    "network": {
      "interfaces": [
        {
          "name": "wlo1",
          "rxBps": 316,
          "txBps": 1550,
          "virtual": false
        },
        {
          "name": "docker0",
          "rxBps": 0,
          "txBps": 0,
          "virtual": true
        }
      ],
      "rxBps": 316,
      "txBps": 1550
    },
    "processes": [
      {
        "command": "node /opt/unduck/node_modules/.bin/vite preview",
        "cpuPercent": 0,
        "memPercent": 0.1,
        "name": "MainThread",
        "pid": 1857,
        "rssKB": 91788,
        "user": "pulkit"
      }
    ],
    "tasks": {
      "runnable": 2,
      "total": 1117
    },
    "uptimeSeconds": 33029
  }
}
```

What the fields mean:

- `host.os` is what the machine calls itself, from `/etc/os-release`, and
  `host.osID` is its short id such as `ubuntu`. `host.virtual` is the
  collector's judgement about whether it is a VM.
- `sample.at` is the sample time, and `sample.intervalSeconds` is how long the
  window behind this sample actually was.
- `cpu.totalPercent` is 0 to 100 across the whole machine, `cpu.corePercent` has
  one entry per logical core in core order, and `cpu.stealPercent` is time the
  hypervisor took, which is 0 on bare metal.
- Every `*KB` number is kilobytes and every `*Bps` number is bytes per second.
  `memory.usedPercent` is `usedKB` over `totalKB`.
- `load` is the one, five and fifteen minute load averages, in that order.
- `disk.devices` is per block device with a `busyPercent`, and
  `network.interfaces` is per interface with a `virtual` flag that labels
  bridges and container interfaces. The flag is a label only: the `rxBps` and
  `txBps` totals add up every interface the machine reports except loopback,
  virtual ones included.
- `processes` is present even when it is empty, so the key never disappears
  between runs. With the default `--processes 0` it is always `[]`. The
  collector sends at most thirty processes, the busiest by CPU plus the largest
  by memory, in no particular order, so `--processes` trims that list rather
  than ranking it.

## Examples

```
ed machines metrics tuf
ed machines metrics tuf --json
ed machines metrics tuf --processes 20
ed machines metrics tuf --follow --interval 5 --json | jq -c '{cpu: .sample.cpu.totalPercent}'
```

## Behaviour notes

Nothing is written locally and nothing is installed remotely. `ed` opens the
shared connection, runs `sh -s -- --once` or `sh -s -- --stream -i <interval>`
there, and pipes the collector script into that shell's stdin. The script needs
a POSIX shell and `awk` and nothing else.

The collector's own stderr is discarded, so a warning on the machine never
pollutes the report.

Failures, with their codes:

- an unknown or ambiguous machine name exits 3
- a machine that cannot be reached exits 4
- a machine that connects but never emits a sample exits 4 with
  `<name> did not report metrics` and the hint that the collector needs a POSIX
  shell and awk
- `--interval 0` or a negative interval exits 2 with
  `--interval must be greater than zero`, and `--processes=-1` exits 2 with
  `--processes cannot be negative`; both are checked before the machine is
  dialled
- a build with the collector script missing exits 1

Write a negative process count as `--processes=-1`. Spelled `--processes -1` the
parser reads it as a missing value and exits 2 for that reason instead.

`--json --follow` writes one compact document per line, forever, repeating the
whole `host` object on every line so each line stands alone for `jq -c`, `head`
or a pipe. Without `--follow` you get a single pretty document.

The collector also emits a slower record carrying filesystems, temperatures,
battery and GPU. `ed machines metrics` decodes and discards it, so those never
appear here even though the app's Machines view shows them.

`ed system stats` is the same report for the Mac you are typing on, in the same
shape, so a script can treat local and remote the same way.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
