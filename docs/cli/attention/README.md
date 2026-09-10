# `ed attention`

`ed attention` reads Edith's local attention ledger. It works with the app closed,
uses the same identity and category rules as the UI, and emits bounded JSON suitable
for scripts and agents. Initial tracking and browser permissions are configured in
the guided Attention screen in Edith.

The background agent owns both native application collection and the browser
listener. Closing the dashboard or quitting the menu bar app leaves Attention
tracking active while `edithd` is enabled. Turn off Attention tracking in its
settings to stop collection. Window titles require Accessibility permission for
the collecting process; application duration does not.

## Commands

- [`ed attention status`](./status.md)
- [`ed attention summary`](./summary.md)
- [`ed attention timeline`](./timeline.md)
- [`ed attention music`](./music.md)
- [`ed attention categories`](./categories/README.md)
- [`ed attention focus`](./focus/README.md)
- [`ed attention doctor`](./doctor.md)

A bare `ed attention` runs `status`. Events live in the background agent's
`~/Library/Application Support/Edith/edith.sqlite` database. Settings, focus sessions,
and pending delivery files live in its `attention` directory. These paths follow
the app's data directory in test or development environments. CLI event queries
report agent failures instead of returning an empty summary.

Summaries resolve overlap before totaling time. A browser heartbeat replaces the
enclosing browser application for that interval, so Chrome and the active site are
not counted twice. Idle application and video time stays visible as idle time but is
not treated as engaged entertainment. Playing audio is reported separately by
`music` even while the Mac is idle.

## Where to go next

- [All command groups](../README.md)
- [`ed attention summary`](./summary.md), the main machine-readable report
- [`ed attention categories`](./categories/README.md), for historical reclassification
