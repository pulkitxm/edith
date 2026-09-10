# `ed audio status`

Shows every live input and output device, the current defaults, the preferred input UID,
and saved per-app routes. This is the default subcommand.

```
ed audio status [--json]
```

Human output is a compact summary:

```
input   Studio Mic
output  Desk Speakers
pin     Studio Mic
routes  2
```

JSON contains `defaultInputUID`, `defaultOutputUID`, `preferredInputUID`, `routes`, and a
`devices` array. Each device reports its `uid`, `name`, input and output support,
headphone classification, and default flags.

```
ed audio
ed audio status --json
```

The command reads Core Audio directly, so Edith does not need to be open. A device
enumeration failure exits 4 and writes the diagnostic to stderr.

## Where to go next

- [`ed audio`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
