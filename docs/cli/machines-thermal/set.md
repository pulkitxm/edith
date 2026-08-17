# `ed machines thermal set`

`ed machines thermal set <machine> <profile>` changes the Linux platform
profile. With no duration it stays selected until another profile is applied.

```
ed machines thermal set <machine> <profile> [--minutes <count>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, SSH alias, UUID or unambiguous prefix | required | Which machine to change. |
| `<profile>` | an exact choice reported by the machine | required | Profile to apply. Names are case-sensitive. |
| `--minutes` | integer from `0` through `10080` | `0` | Revert after this many minutes. Zero keeps the profile until changed. |
| `--json` | flag | off | Emit one result object on stdout. |

```sh
ed machines thermal set tuf performance
ed machines tuf thermal set performance --minutes 30
ed machines thermal set tuf balanced --json
```

`--minutes <count>` schedules a reversion to the profile that was active before
the first temporary change. It accepts 0 through 10080 minutes. Zero means
until changed. The app offers 15 minutes, 30 minutes, 1 hour, 2 hours and until
changed.

Before writing anything, the command reads the machine's choices and refuses a
profile that is not in that list. A permanent change cancels a pending timed
reversion. A second temporary change replaces the timer while preserving the
original destination.

JSON returns `machine`, `profile`, `temporary` and `minutes`:

```json
{
  "machine": "Asus TUF 7",
  "minutes": 30,
  "profile": "performance",
  "temporary": true
}
```

The command first performs the same 15-second read as `status`, then gives the
write 30 seconds. `--minutes` outside the accepted range exits 2 before the
machine is resolved. An unknown profile exits 3 and lists the machine's valid
choices. An unknown or ambiguous machine also exits 3. An unreachable machine
or missing readable platform profile support exits 4.

After validation, any remote write failure exits 1. This includes a refused
sudo password, missing write privilege, `systemd-run` missing for a temporary
profile, timer creation failure, or platform support disappearing between the
read and write. Privilege failures include a hint to store or replace the sudo
password. If timer creation fails after the profile write, the remote script
restores the original profile and removes its saved state before reporting the
failure.

[Back to `ed machines thermal`](./README.md) or [all CLI commands](../README.md).
