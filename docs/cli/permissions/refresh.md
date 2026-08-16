# `ed permissions refresh`

Ask the running app to re-read the real TCC state, then print the refreshed
mirror. Run it when you suspect what `ls` showed you is stale.

```
ed permissions refresh [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout |

## `--json` shape

A top-level array, not an object, carrying the same nine permission objects `ls`
puts under its `permissions` key. There is no `appRunning` field, because the
command cannot get this far with the app closed. Trimmed here to two rows:

```json
[
  {
    "blocksEnabledExtension": true,
    "granted": false,
    "grantsOnFirstUse": false,
    "id": "calendar",
    "name": "Calendar",
    "optionalFor": [],
    "reason": "Required to read and show your schedule in Calendar.",
    "requiredBy": [
      "calendar"
    ],
    "usedByEnabledExtension": true
  },
  {
    "blocksEnabledExtension": false,
    "granted": true,
    "grantsOnFirstUse": false,
    "id": "notifications",
    "name": "Notifications",
    "optionalFor": [
      "usage",
      "machines"
    ],
    "reason": "Asked when you enable usage limit, pacing, or reset alerts.",
    "requiredBy": [],
    "usedByEnabledExtension": true
  }
]
```

## Examples

```
ed permissions refresh
ed permissions refresh --json | jq -r '.[] | select(.blocksEnabledExtension) | .id'
```

## Behaviour

It requires the menu bar app, posts one refresh notification, sleeps 1200 ms,
and prints what the mirror says then. The sleep is fixed rather than a reply it
waits on, so a machine under load can print a mirror the app is still mid-way
through updating; running it twice costs nothing.

The human table is narrower than the one `ls` prints, two columns and no
`blocking` marker, and its `STATE` is only ever `granted` or `no`. That is why
`bluetooth` and `automation` read `no` here and `on first use` under `ls`:

```
$ ed permissions refresh
PERMISSION       STATE
calendar         no
notifications    granted
accessibility    granted
inputMonitoring  granted
fullDisk         no
screenRecording  granted
camera           granted
bluetooth        no
automation       no
```

With Edith closed:

```
$ ed permissions refresh
error: refreshing permissions needs the Edith menu bar app to be running
hint: start Edith, then retry
```

Refreshing makes the menu bar helper rewrite any of its six mirror settings the
real state has moved under, `calendar` excepted for the reason given above, so
it is the one command here that leaves stored state changed, and what it changes
is only Edith's record of what macOS had already decided.

## Where to go next

- [`ed permissions`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
