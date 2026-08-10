# `ed usage machines`

Counts the agents running on your SSH machines alongside the ones on this Mac.
`ed usage machines` on its own runs `ls`.

The collector Edith runs here is piped to the machine and run against that
machine's home directory, and the numbers come back into the same `usage.json`
the dashboard reads. Each agent on a machine arrives as its own source, named
`<machine-slug>:<agent>`, so `ed usage summary` counts the fleet, `--source
asus-tuf-7:cli` narrows to one agent on one machine, and `--machine` narrows to
everything one machine ran.

Whatever the collector needs and cannot find there, jq, bun and ccusage, is
installed under `~/.cache/edith` on that machine. That is why collecting waits
to be asked rather than happening for every machine you have configured, and why
the first run on a machine can take minutes.

## `ed usage machines ls`

Lists every configured machine, whether it is counted, and what it has given.

```
ed usage machines ls [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout |

`--json` shape, an array with one object per configured machine, whether or not
it has ever been collected:

```json
[
  {
    "collectedAt": "2026-08-08T16:14:51Z",
    "cost": 249.81,
    "counted": true,
    "days": 81,
    "host": "asus-tuf-7",
    "id": "1F0A9C22-4E64-4C63-9E0B-2F5A1E7D2C10",
    "machine": "Asus TUF 7",
    "sources": ["asus-tuf-7:cli"],
    "tokens": 321812580
  }
]
```

A machine that has never been collected still appears, with `collectedAt` and
`host` as `null`, `sources` empty, and `days`, `cost` and `tokens` at zero. The
human table writes `-` in those columns instead.

```
$ ed usage machines
MACHINE     COUNTED  COLLECTED             SOURCES  COST    TOKENS
Asus TUF 7  yes      2026-08-08T16:14:51Z  1        249.81  321812580
```

Reads only, mutates nothing, needs no app. With no machines configured at all it
exits 3 with `no machines are configured`.

## `ed usage machines collect`

Runs the collector on a machine over the shared SSH connection and folds the
result in.

```
ed usage machines collect [<machine>] [--once] [--verbose] [--timeout <seconds>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias or id | every machine already taking part | Which machine to collect. Naming one also signs it up for later refreshes unless `--once` is passed |
| `--once` | flag | off | Collect without signing the machine up, so later refreshes skip it |
| `--verbose` | flag | off | Print everything the collector said on the machine, on stderr |
| `--timeout` | integer seconds, greater than 0 | `900` | Give up on a machine after this long |
| `--json` | flag | off | Emit JSON on stdout |

`--json` shape:

```json
{
  "collected": [
    {
      "cost": 249.81,
      "days": 81,
      "id": "1F0A9C22-4E64-4C63-9E0B-2F5A1E7D2C10",
      "machine": "Asus TUF 7",
      "sources": ["cli"],
      "tokens": 321812580
    }
  ],
  "failed": [],
  "merged": true
}
```

`sources` names the agents as that machine knows them, so `cli` there is the
source `asus-tuf-7:cli` once it has been folded in.

`merged` says whether the numbers reached `usage.json`. The command runs the
merge itself, in this process, so it does not need the app; it is `false` only
when the merge could not run at all, and the numbers then sit on disk until the
next `ed usage refresh`. A refresh already running elsewhere counts as merged,
because that run picks the new files up.

Progress goes to stderr as each machine lands, so stdout stays parseable:

```
  ▸ Asus TUF 7  5 days · 1 agent                   7.19s
```

Two collections never run at once. The second stands aside with `another
collection is already running`, whether it came from another `ed`, the menu bar
app's own half-hourly round, or the button in Settings.

```
ed usage machines collect "Asus TUF 7"
ed usage machines collect tuf --once
ed usage machines collect --timeout 1800 --verbose
ed usage machines collect --json | jq '.collected[].sources'
```

Failures are per machine rather than fatal: a machine that cannot be reached is
listed in `failed` with its error while the others still count. The command only
fails when nothing at all was collected, and then it exits 4 with the first
error. With no machine named and none signed up yet it exits 3 with `no machine
is counted towards usage yet`. A `--timeout` of zero or less exits 2.

Collecting also prunes stored usage for machines that are no longer in the
directory, so removing a machine and collecting again forgets it.

## `ed usage machines enable`

Signs a machine up so every later refresh collects it.

```
ed usage machines enable <machine> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias or id | required | Which machine to count |
| `--json` | flag | off | Emit JSON on stdout |

```json
{
  "counted": true,
  "machine": "Asus TUF 7"
}
```

This only changes whether the machine takes part; it collects nothing by itself,
so a machine enabled but never collected still reports nothing until a refresh
runs. A name that matches no machine exits 3.

## `ed usage machines disable`

Stops collecting from a machine while keeping the numbers it already gave.

```
ed usage machines disable <machine> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias or id | required | Which machine to stop collecting |
| `--json` | flag | off | Emit JSON on stdout |

```json
{
  "counted": false,
  "machine": "Asus TUF 7"
}
```

The machine's existing sources stay in `usage.json` and keep counting towards
every total. Use `forget` to drop them. A name that matches no machine exits 3.

## `ed usage machines forget`

Drops everything a machine gave and stops counting it.

```
ed usage machines forget <machine> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias or id | required | Which machine to drop |
| `--json` | flag | off | Emit JSON on stdout |

```json
{
  "dropped": true,
  "machine": "Asus TUF 7",
  "merging": true
}
```

`dropped` is `false` when there was nothing stored for that machine, and then
`merging` is `false` too, because the fold only runs when something actually
went away. That fold is the same in-process pipeline `ed usage refresh` runs, so
no app is involved: the numbers leave `usage.json` there and then. A refresh
already running elsewhere counts as merged, since it will pick the change up.
This is the one verb here that accepts a raw id for a machine that is no longer
in the directory, so usage left behind by a deleted machine can still be
cleared.

## Where to go next

- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
