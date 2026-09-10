# `ed audio input`

Selects an input device and remembers it as Audio Controls' preferred input.

```
ed audio input <device-or-system> [--json]
```

`device` is either the exact case-insensitive device name or its Core Audio UID. Shell
completion offers both. The selection is applied before it is saved, so a failed switch
does not leave behind a pin that never worked.

Pass `system` to remove the preferred input. That does not force another device at the
moment of the command. It stops Audio Controls from reapplying a pin, leaving later input
selection to macOS and the user.

```
ed audio input "Studio Mic"
ed audio input BuiltInMicrophoneDevice
ed audio input system --json
```

When Audio Controls is active, a pinned device is reapplied whenever it becomes available.
Disabling the extension restores the input that was active before Edith first applied the
pin only when Edith still owns the current selection.

## Where to go next

- [`ed audio`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
