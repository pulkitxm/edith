# `ed lid-awake off`

Ends the requested Lid Awake session and restores normal lid-close sleep.
`stop` is an alias.

```
ed lid-awake off [--json]
```

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit the full resulting state object. |

```
ed lid-awake off
ed lid-awake stop
ed lid-awake off --json
```

The menu bar app must be running, even when the extension is already off. The
command waits as long as 120 seconds for the engine and exits 0 only after the
request was applied. Repeating it while already off is a successful no-op. The
human answer is `lid awake off`; JSON is the full state object documented by
[`status`](./status.md), with `active` and `requestedActive` false after a
successful stop.

An app that does not answer exits 4. A helper or `pmset` failure exits 1 with
the runtime error. This command does not disable the extension, change the
battery threshold, or change `restore-on-quit`.

## Where to go next

- [`ed lid-awake`](./README.md), the rest of this group
- [`ed lid-awake status`](./status.md), verify the live result
- [`ed extensions disable lidAwake`](../extensions/disable.md), turn the extension off
- [All `ed` commands](../README.md)
