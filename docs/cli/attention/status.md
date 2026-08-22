# `ed attention status`

Shows whether native and browser tracking are enabled, the privacy level, events in
the last 24 hours, imported history inventory size, helper state, and active focus
session.

```
ed attention status [--json]
```

The JSON object contains `trackingEnabled`, `browserTrackingEnabled`,
`privacyLevel`, `windowTitlesEnabled`, `iCloudBackupEnabled`,
`eventsLast24Hours`, `historySites`, `helperRunning`, and `focus`. The focus value
is `null` when no session is active.

## Where to go next

- [CLI index](../README.md)
- [`ed attention doctor`](./doctor.md)
