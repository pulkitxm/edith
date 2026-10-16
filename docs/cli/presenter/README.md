# `ed presenter`

Reads and controls the same manual presenter runtime used by the Settings,
Home, and notch toggles.

```text
ed presenter status [--json]
ed presenter start [--json]
ed presenter stop [--json]
```

A bare `ed presenter` runs `status`. Plain status is `active` or `inactive` and
names whether an active session is manual or automatic. JSON reports `action`,
`enabled`, `manual`, `autoActive`, `autoReason`, and `active`.

`start` and `stop` act only while the Presenter extension is enabled. They exit
4 otherwise. `stop` also pauses the automatic detector, matching every existing
SwiftUI runtime toggle.

Shell completion offers `status`, `start`, and `stop` under the group.

- [`ed extensions`](../extensions/README.md)
- [`ed config`](../config/README.md)
- [All command groups](../README.md)
