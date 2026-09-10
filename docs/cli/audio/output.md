# `ed audio output`

Switches the default output for application audio and system alert sounds.

```
ed audio output <device> [--json]
```

`device` is an exact case-insensitive output name or a Core Audio UID. Use
`ed audio status` to inspect both values. Unlike `input` and `route`, this command does not
accept `system`, because the system output is the device being selected.

```
ed audio output "Desk Speakers"
ed audio output 1234-5678-output --json
```

The command changes Core Audio directly and then notifies Edith so device lists and saved
routes refresh. A missing device exits 3. A Core Audio switch failure exits 4.

## Where to go next

- [`ed audio`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
