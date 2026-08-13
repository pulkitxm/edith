# `ed machines thermal status`

`ed machines thermal status <machine>` reports the active Linux platform
profile and every profile offered by the machine.

```sh
ed machines thermal status tuf
ed machines tuf thermal status
ed machines thermal status tuf --json
```

The human form prints `MACHINE`, `CURRENT` and `AVAILABLE` columns. JSON returns
one object with `machine`, `current` and `choices` fields.

This command exits 4 when the machine cannot be reached or does not expose both
platform profile sysfs files. It does not need sudo and does not change the
machine.

Fan RPM is streamed into the Cooling card in the app by the normal machine
metrics connection. The status command focuses on the writable profile state.

[Back to `ed machines thermal`](./README.md) or [all CLI commands](../README.md).
