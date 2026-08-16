# `ed lid-awake on`

Starts a Lid Awake session and waits until macOS sleep state was changed.
`start` is an alias.

```
ed lid-awake on [--for <duration> | --until-lid-reopens] [--json]
```

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--for` | `15m`, `30m`, `1h`, `2h`, or an accepted long spelling | none | Stop automatically after the selected preset. |
| `--until-lid-reopens` | flag | off | Stop after the lid has closed and then opens again. |
| `--json` | flag | off | Emit the full resulting state object. |

Without a session option the command selects `indefinite`. Accepted duration
spellings are case-insensitive and ignore spaces:

| Session | Accepted values |
| --- | --- |
| 15 minutes | `15m`, `15min`, `15mins`, `15minute`, `15minutes`, `fifteenminutes` |
| 30 minutes | `30m`, `30min`, `30mins`, `30minute`, `30minutes`, `thirtyminutes` |
| 1 hour | `1h`, `60m`, `60min`, `60mins`, `1hour`, `onehour` |
| 2 hours | `2h`, `120m`, `120min`, `120mins`, `2hours`, `twohours` |

`--for` and `--until-lid-reopens` together are refused with exit 1. An unknown
duration also exits 1 and hints `use 15m, 30m, 1h or 2h`.

```
ed lid-awake on
ed lid-awake start --for 30min
ed lid-awake on --until-lid-reopens
ed lid-awake on --for 1h --json
```

The menu bar app must be running, otherwise this exits 4 before posting a
request. Starting enables the `lidAwake` extension when needed, waits as long as
120 seconds for the engine, and exits 0 only after the privileged helper has
applied the change. The human answer is the selected session, for example
`lid awake on: 30 minutes`. JSON is the full state object documented by
[`status`](./status.md).

On first use, macOS may require approval for Edith's background helper. The
command opens Login Items settings and exits 1 with the approval instruction.
Approve the Edith item that affects all users, then run the command again. A
missing helper instead asks you to reinstall Edith. There is no password prompt
or direct unprivileged fallback.

## Where to go next

- [`ed lid-awake`](./README.md), the rest of this group
- [`ed lid-awake status`](./status.md), inspect the live result
- [`ed lid-awake off`](./off.md), end the session
- [All `ed` commands](../README.md)
