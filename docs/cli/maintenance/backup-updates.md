# `ed maintenance backup-updates`

[`ed maintenance`](./README.md)

[The `ed` command line](../README.md)

```bash
ed maintenance backup-updates <new-file> [--json]
```

Copies ignored versions, snoozes, exclusions, refresh time, and update history to a new JSON file. The destination must not already exist. The command does not expose credentials because the update store contains policy and results only.
