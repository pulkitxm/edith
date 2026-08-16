# `ed machines thermal`

`ed machines thermal` reads Linux fan sensors and controls the kernel platform
profile exposed by a machine. The Machines overview shows every readable hwmon
fan in RPM alongside the active profile and the choices the kernel reports.

Profile changes can stay active until changed again, or revert after a chosen
number of minutes. Timed changes run through a transient systemd timer on the
machine, so the reversion still happens if Edith closes or the SSH connection
drops. Starting another timed change keeps the original profile as the eventual
destination. Applying a permanent profile cancels any pending reversion.

The machine needs `/sys/firmware/acpi/platform_profile` and
`platform_profile_choices` for profile controls. Fan readings come from
`/sys/class/hwmon/hwmon*/fan*_input`. Machines without either interface simply
omit the matching part of the Cooling card.

## Commands

- [`ed machines thermal status`](./status.md)
- [`ed machines thermal set`](./set.md)

## Privilege and safety

Reading profile state and fan speeds needs no privilege on a normal Linux
installation. Writing the profile usually needs root. Edith uses the sudo
password stored by `ed machines edit <machine> --sudo-password-stdin`, or
passwordless sudo when no password is stored. The password goes on standard
input and is never placed in the command line.

Profile names are accepted only when the machine reports them as a choice. The
command also restricts names to letters, digits, hyphens and underscores before
building any shell command.

Timed changes require `systemd-run`. Scheduling is checked before the profile
is changed. If timer creation fails after the write, the command restores the
original profile immediately and reports failure.

## Where to go next

- [`ed machines`](../machines/README.md) for machine setup and live metrics.
- [`ed machines power`](../machines-power/README.md) for reboot, shutdown and service controls.
- [The `ed` command line](../README.md) for the complete reference.
