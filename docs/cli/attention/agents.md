# `ed attention agents`

Reports how long Herdr agents worked and waited, on every machine, per agent kind
and per project, next to how long you spent watching them in Edith.

```
ed attention agents [--range <window>] [--limit <count>] [--json]
```

The background agent samples every Herdr agent on this Mac and on each SSH machine
while Attention and agent tracking are on. A working agent adds working time and a
blocked one adds waiting time. Sampling continues while the screen is locked, so
time agents spend working unattended is counted. Remote machines are polled about
every two minutes, so their intervals are accurate to that resolution.

`watched` is the time you spent in Edith looking at a session on that machine, with
that agent or in that project.

The default range is `today` and the default limit is 20 sessions. The JSON
document has `workingSeconds`, `blockedSeconds`, `attendedSeconds`,
`peakConcurrent`, and `machines`, `agents`, `projects` and `sessions` arrays.

## Where to go next

- [CLI index](../README.md)
- [`ed attention breakdown`](./breakdown.md)
