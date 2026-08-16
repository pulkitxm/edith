# `ed machines power wake`

Sends a wake-on-LAN magic packet to the machine's stored MAC address.

```
ed machines power wake <machine> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias or id | required | Which machine to wake. Resolved from the machine file, so it works while the machine is off. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the human line. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines power wake studio
sent a wake packet to 04:42:1a:8d:2f:6c
```

## `--json` shape

```json
{
  "action": "wake",
  "applied": true,
  "macAddress": "04:42:1a:8d:2f:6c",
  "machine": "Studio Mac"
}
```

`applied: true` means the packet left this Mac. It is not a claim that the
machine woke.

## Examples

```
ed machines power wake studio
ed machines studio power wake
ed machines power wake studio --json
ed machines edit studio --mac 04:42:1a:8d:2f:6c
```

## Behaviour notes

There is no SSH here at all. `ed` builds the magic packet by hand, six `0xFF`
bytes followed by the six address bytes repeated sixteen times, opens a UDP
socket with `SO_BROADCAST`, and sends it to `255.255.255.255` on port 9. That is
a limited broadcast, so it reaches the local link and no further: waking a
machine on another subnet needs a router that forwards directed broadcasts, and
this command cannot arrange that for you.

Edith learns the address the first time it sees the machine up, by walking
the remote Mac's hardware-port list and picking a real network interface. An interface only counts
when it has a `device` symlink, which is what separates a card from a bridge, a
veth or a loopback, and an address that is empty or all zeroes is skipped.
Wired wins: the first non-wireless card ends the search immediately, while a
wireless one is only remembered as a fallback and used when nothing wired
turned up. Waking over Wi-Fi needs the card to support it, so a machine that
only reports a wireless address may store one and still not wake.

Until that has happened there is nothing to send to, and the command exits 4:

```
$ ed machines power wake box
error: no MAC address is stored for Home Box
hint: open the machine in Edith while it is up so it can learn one, or set it with `ed machines edit Home Box --mac <address>`
```

The hint quotes the display name verbatim, so a name with spaces needs quoting
when you retype the suggestion.

A stored value that is not six colon-separated hex pairs exits 1 with
`<value> is not a MAC address`, and a socket that cannot be opened or written
exits 1 with `Could not open a socket.` or `The wake packet could not be sent.`.
Nothing here depends on the machine being reachable, which is the whole point of
the verb.

## Where to go next

- [`ed machines power`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
