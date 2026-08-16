# `ed system disks`

Lists the mounted volumes with their size, free space and how full they are.

```
ed system disks [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the table. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

The table has one row per volume, and prints its headings even when there are no
rows:

```
$ ed system disks
VOLUME        MOUNT  SIZE    FREE    USED
Macintosh HD  /      494 GB  170 GB  66%
```

## `--json` shape

Four keys, always all four:

```json
{
  "battery": {
    "percent": 99,
    "status": "Finishing Charge"
  },
  "filesystems": [
    {
      "availableKB": 166164022,
      "filesystem": "Macintosh HD",
      "mount": "/",
      "totalKB": 482797652,
      "usedKB": 316633630,
      "usedPercent": 65.58309235522131
    }
  ],
  "gpu": null,
  "temperatures": []
}
```

`filesystem` is the volume's name, not its device node, and `mount` is where it
is mounted. `usedKB` is `totalKB` minus `availableKB`, and `usedPercent` is
`usedKB` over `totalKB`.

`battery` is read from `pmset -g batt` and carries `percent` and a capitalised
`status` such as `Charging`, `Discharging` or `Finishing Charge`. It is `null`
on a Mac with no battery, and `null` rather than missing, so the key is always
there.

`temperatures` and `gpu` are part of the shared report shape the Linux collector
fills in for a remote machine. The local sampler collects neither, so on this
Mac `temperatures` is always `[]` and `gpu` is always `null`. No `ed` command
prints a remote machine's values either: `ed machines metrics` keeps the sample
half and drops the volume, battery, temperature and GPU record, which reaches
the app's Machines window instead. The keys, when a machine does report them,
are:

```json
{
  "gpu": {
    "memTotalMB": 8188,
    "memUsedMB": 1204,
    "name": "NVIDIA GeForce RTX 4060",
    "temperature": 47,
    "utilPercent": 12
  },
  "temperatures": [
    {
      "celsius": 43.5,
      "label": "Package id 0"
    }
  ]
}
```

## Examples

```
ed system disks
ed system disks --json
ed system disks --json | jq -r '.filesystems[] | "\(.mount) \(.usedPercent | floor)%"'
```

## Behaviour notes

Read only, instant, and needs neither the app nor a permission. The one
subprocess it runs is `pmset`, for the battery line, and a `pmset` that fails to
run is reported as `battery: null` rather than as an error.

Only volumes macOS marks browsable and not hidden, and that report a capacity
above zero, are listed, so the Preboot, Recovery and VM volumes that `mount` and
`df` show do not appear here.

Free space is the space macOS calls available for important usage, which counts
purgeable caches it would evict for you. That is the figure Finder shows, and it
is usually larger than what `df` prints for the same volume.

This is one of the few commands that does not run inside the CLI's failure
wrapper, which changes nothing you can observe: the top level reports and codes
a failure identically.

## Where to go next

- [`ed system`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
