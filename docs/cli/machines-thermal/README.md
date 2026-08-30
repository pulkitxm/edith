# `ed machines thermal`

`ed machines thermal` inspects and controls the Linux kernel platform profile or
Windows power scheme exposed by a machine. The app's Control Center separately
shows every readable Linux hwmon fan in RPM alongside the active profile. There is
no fan-speed write command and the CLI does not print fan RPM.

Profile changes can stay active until changed again, or revert after a chosen
number of minutes. Linux timed changes use a transient systemd timer. Windows
timed changes use a hidden PowerShell process and `powercfg`. The reversion still
happens if Edith closes or the SSH connection drops. Applying another profile
replaces the pending reversion, and a permanent profile cancels it.

The machine needs `/sys/firmware/acpi/platform_profile` and
`platform_profile_choices` for profile controls. Fan readings come from
`/sys/class/hwmon/hwmon*/fan*_input`. Windows reads its choices from
`powercfg /list`. Machines without a supported interface simply omit the matching
part of Control Center.

`status` is the default subcommand, so `ed machines thermal tuf` and
`ed machines thermal status tuf` are equivalent. The
machine-first form also works: `ed machines tuf thermal status`.

## Commands

- [`ed machines thermal status`](./status.md)
- [`ed machines thermal set`](./set.md)

## Privilege and safety

Reading profile state needs no privilege on a normal installation. Linux profile
writes usually need root. `ed` uses the sudo password stored by
`ed machines edit <machine> --sudo-password-stdin`, or passwordless sudo when no
password is stored. The password goes on standard input and is never placed in
the command line. Windows power schemes run as the connected user and do not
consume the stored sudo password.

Profile names are accepted only when the machine reports them as a choice. Linux
names are restricted to letters, digits, hyphens and underscores. Windows scheme
names may contain spaces and are passed as PowerShell literals.

Linux timed changes require `systemd-run`. Scheduling is checked before the
profile is changed. If timer creation fails after the write, the command restores
the original profile immediately and reports failure.

Both commands reuse Edith's shared SSH connection and the normal machine
resolver. Names are matched case-insensitively as an exact name, SSH alias or
UUID first, then as an unambiguous name or alias prefix. An unknown or ambiguous
machine exits 3, and an unreachable machine exits 4.

## Where to go next

- [`ed machines`](../machines/README.md) for machine setup and live metrics.
- [`ed machines power`](../machines-power/README.md) for reboot, shutdown and service controls.
- [The `ed` command line](../README.md) for the complete reference.
