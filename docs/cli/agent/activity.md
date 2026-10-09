# `ed agent activity`

`ed agent activity status` reads coding sessions and permission requests observed
by the background agent through configured provider hooks.

```
ed agent activity status [--json]
```

The table shows each session's provider, identifier, state, and current tool.
It also prints the number of pending approvals. JSON includes the complete
activity snapshot, including sessions and approval requests.

This command does not enable integrations or approve requests. Configure
providers in Agent activity settings and make permission decisions in the app
or Notch. The command exits 4 when the background agent is unavailable.

## Where to go next

- [`ed agent status`](./status.md), for the background agent's own health
- [`ed agent`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
