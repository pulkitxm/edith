# `ed machines thermal status`

`ed machines thermal status <machine>` reports the active Linux platform
profile and every profile offered by the machine. It is the group's default
subcommand.

```
ed machines thermal status <machine> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, SSH alias, UUID or unambiguous prefix | required | Which machine to inspect. |
| `--json` | flag | off | Emit one state object on stdout. |

```sh
ed machines thermal status tuf
ed machines tuf thermal status
ed machines thermal status tuf --json
```

The human form prints `MACHINE`, `CURRENT` and `AVAILABLE` columns. JSON returns
one object with `machine`, `current` and `choices` fields:

```json
{
  "choices": [
    "low-power",
    "balanced",
    "performance"
  ],
  "current": "balanced",
  "machine": "Asus TUF 7"
}
```

The command runs a 15-second remote read. It succeeds only when both
`/sys/firmware/acpi/platform_profile` and
`/sys/firmware/acpi/platform_profile_choices` are readable, the current value
contains only letters, digits, hyphens or underscores, and the current value is
one of the reported choices.

This command exits 4 when the machine cannot be reached or does not expose both
platform profile sysfs files. An unknown or ambiguous machine exits 3. It does
not need sudo and does not change the machine.

Fan RPM is streamed into the Cooling card in the app by the normal machine
metrics connection. The status command focuses on the writable profile state.

[Back to `ed machines thermal`](./README.md) or [all CLI commands](../README.md).
