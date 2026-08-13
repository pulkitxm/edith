# `ed machines thermal set`

`ed machines thermal set <machine> <profile>` changes the Linux platform
profile. With no duration it stays selected until another profile is applied.

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

JSON returns `machine`, `profile`, `temporary` and `minutes`. A privilege error
exits 1 with a hint explaining how to store a sudo password. An unknown profile
exits 3 and lists the machine's valid choices. Missing platform profile support
or `systemd-run` exits 4.

[Back to `ed machines thermal`](./README.md) or [all CLI commands](../README.md).
