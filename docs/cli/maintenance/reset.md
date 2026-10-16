# `ed maintenance reset`

Clears ignored, snoozed and excluded update policy.

[`ed maintenance`](./README.md)

Usage:

```
ed maintenance reset [--yes] [--json]
```

Without `--yes` this prints the plan and changes nothing. History stays.

Examples:

```
ed maintenance reset
ed maintenance reset --yes
```

See also:

- [`ed maintenance exclude`](./exclude.md)
- [`ed maintenance`](./README.md)
- [`ed`](../README.md)
