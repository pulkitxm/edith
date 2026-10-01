# `ed maintenance snooze`

Hides one update until a duration from now.

[`ed maintenance`](./README.md)

Usage:

```
ed maintenance snooze <id> --for <duration> [--json]
```

Durations look like `12h` or `7d`.

Examples:

```
ed maintenance snooze firefox --for 7d
ed maintenance snooze firefox --for 7d --json
```

See also:

- [`ed maintenance ignore`](./ignore.md)
- [`ed maintenance`](./README.md)
- [`ed`](../README.md)
