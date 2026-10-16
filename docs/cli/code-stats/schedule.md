# `ed code-stats schedule`

[`ed code-stats`](./README.md)

[The `ed` command line](../README.md)

```bash
ed code-stats schedule manual|daily|weekly [--hour 0-23] [--weekday 1-7] [--json]
```

Chooses how often the agent refreshes on its own. `daily` runs at `--hour`, and `weekly` runs on `--weekday` (1 is Sunday, 7 is Saturday) at `--hour`. Options you leave out keep their current values, 09:00 on Monday by default. Scheduling starts after the first refresh you run yourself. A refresh missed while the Mac slept or the drive was unplugged runs once as soon as it can, and a due refresh is skipped while the Mac is under serious thermal pressure.
