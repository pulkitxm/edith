# `ed maintenance ignore`

Ignores one available update version.

[`ed maintenance`](./README.md)

Usage:

```
ed maintenance ignore <id> --available <version> [--json]
```

This writes the ignored-version policy the update list uses. A newer version of the same item still appears.

Examples:

```
ed maintenance ignore firefox --available 120.0
ed maintenance ignore firefox --available 120.0 --json
```

See also:

- [`ed maintenance snooze`](./snooze.md)
- [`ed maintenance`](./README.md)
- [`ed`](../README.md)
