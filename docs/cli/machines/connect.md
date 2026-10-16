# `ed machines connect`

Opens the shared SSH connection to a machine and reports the round trip time.

```
ed machines connect <machine> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the line. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines connect tuf
connected, 28 ms
```

## `--json` shape

```json
{
  "connected": true,
  "latencyMillis": 26.595375,
  "machine": "Asus TUF 7"
}
```

`machine` here is the name, not the record. `latencyMillis` is `null`, and the
human line drops the timing and reads just `connected`, when the timing probe
did not come back.

## Examples

```
ed machines connect tuf
ed machines connect tuf --json | jq .latencyMillis
```

## Behaviour notes

If a live socket already exists, whether the app opened it or an earlier `ed`
call did, this reuses it and only measures. Otherwise it starts a ControlMaster
and waits up to 25 seconds for the socket to answer.

The latency is measured by running `true` on the machine and timing the round
trip, so it includes ssh's own overhead on an established channel rather than
being a network ping.

A machine that cannot be reached exits 4 with ssh's reason translated into a
sentence: a changed host key, a rejected credential, a refused connection, a
timeout or an unresolvable name each get their own wording. An unknown machine
name exits 3.

The socket outlives the process. `ControlPersist=10m` keeps it up for ten idle
minutes, which is what makes the next command on that machine fast.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
