# Background agent architecture and verification

Edith uses `edithd` as the single owner for scheduled work, durable tasks, shared
state collection, and operations that must outlive a window. The main application and
menu bar helper are presentation processes. They request work over XPC and subscribe to
snapshots instead of running duplicate collectors.

This document records the audited ownership boundary, the live diagnostics available
in the product, the resource policy, and the ordered end-to-end verification procedure.

## Process boundary

Edith ships one application bundle with three process roles:

| Process | Responsibility | Lifetime |
| --- | --- | --- |
| `Edith` | Windows, SwiftUI state, direct user interaction, and command line presentation | User controlled |
| Nested `Edith` login item | Menu bar, pasteboard capture, media controls, overlays, and permission-bound UI | Login item |
| `edithd` | Schedules collectors, owns durable tasks, persists diagnostics, and publishes shared snapshots | LaunchAgent |

The processes share `EdithKit` models and protocols from one Swift package. They do not
ship independent copies of the product logic. macOS still requires a separate login item
for menu bar behavior and a separate LaunchAgent for work that survives the UI. Keeping
those executable boundaries preserves login item management, XPC identity checks, and
permission ownership while the shared package provides one implementation roof.

UI code should keep work only when it requires an AppKit or SwiftUI lifetime, a visible
window, the general pasteboard, a user gesture, or a permission held by that process.
Everything else should use one of the daemon paths below.

## Daemon-owned work

### Scheduled jobs

`AgentJobPlan` is the source of truth for recurring jobs. `JobScheduler` serializes each
job ID, publishes state changes, records completion or failure, and applies subscription,
power, and cadence policy.

| Job | Trigger | Ambient cadence | Live cadence | Published topic |
| --- | --- | ---: | ---: | --- |
| Usage cost refresh | File changes | 15 minutes | 15 minutes | Usage |
| Agent rate limits | Timer | 15 minutes | 5 minutes | Limits |
| Herdr session discovery | Subscription | Off | 2 seconds | Sessions |
| Machine health probe | Timer | 5 minutes | Same | Machines |
| Machine metrics stream | Subscription | Off | 5 seconds | Machine metrics |
| Update discovery | Timer | 6 hours | Same | Updates |
| Weekly cleaner estimate | Timer | 7 days | Same | Cleaner |
| Download queue | Queue | On demand | On demand | Downloads |
| Attention ingestion | Timer | 15 minutes | 15 minutes | Attention |
| Memory health | Timer | 1 minute | 20 seconds | Companion |
| iCloud backup | File changes | 1 day | Same | Backup |

Filesystem notifications are hints, not permission to bypass cadence. The usage watcher
debounces changes for 30 seconds and then calls `enqueueIfDue`. A completed refresh sets
the next eligible time from completion, so active transcript files cannot keep a costly
collector running continuously. A manual run remains immediate.

Each job declares an ability when it belongs to an optional extension. Disabled
extensions do not consume collector resources. Subscriber counts select a live cadence
only while a visible surface is listening. Power policy can pause ambient jobs on battery
or while the screen is locked.

### Durable tasks

`AgentTaskService` owns work that needs progress, cancellation, retained output, or a
result after the submitting UI disappears. The registered workflows cover storage
inspection, site audits, machine operations, and download estimates. Tasks have bounded
concurrency, persisted terminal states, explicit cancellation, and a retained event ID.

The app and CLI submit task specifications and inspect task receipts. They do not retain
the process that performs the work. A daemon restart marks interrupted active tasks and
keeps completed history available for diagnosis.

### Daemon operations

Short shared operations use typed XPC requests. Current services include clipboard
storage, favicons, notification delivery and acknowledgement, Attention storage,
download queue mutations, machine metrics, task control, and diagnostics. Public user
operations and internal transport operations have separate catalogs. Callers use the
typed public path for usage refresh and rate limit refresh, which prevents a client from
rejecting an operation the daemon actually serves.

A usage refresh request returns only after the worker has acquired its cross-process
lock or the requested run has already completed. This closes the startup interval where
a client could accept the request and then incorrectly report that no refresh was
running. Concurrent requests still share one scheduler flight and one publication.

## Shared data and publication

The daemon store is a WAL-backed SQLite database. It retains job runs, bounded structured
events, task state, usage summaries, limit samples, machine metrics, update candidates,
cleaner estimates, downloads, Attention events, and Memory health.

Usage collection publishes through a staged file and three lock levels:

1. `refresh.lock` admits one collector.
2. `usage-transaction.lock` serializes archive mutation and publication.
3. `usage-data.lock` protects the final read, merge, and atomic replacement.

The collector writes to a private staging file. Publication validates the new document,
merges retained day and source blocks from the baseline, rebases any concurrent live
replacement, folds machine snapshots, validates again, and atomically replaces
`usage.json`. Failed staging or validation leaves the previous document intact.

Billing history is retained in SQLite by stable source identity. Generated links are not
followed. Large numeric costs are normalized before comparison so native JSON spelling
differences do not replace exact retained baselines. Clipboard persistence likewise
loads the complete saved archive before applying the configured in-memory capture limit,
so restarting the daemon cannot truncate older entries.

## Live diagnostics in the app

Settings contains a Background Agent pane backed by the same XPC snapshots used by the
CLI. It shows:

- Registration, build, process ID, uptime, memory, CPU, subscriber count, and store schema.
- Every scheduled job, its phase, trigger, cadence, subscriber count, run count, latest
  duration, and latest failure.
- Run and cancel controls for scheduled jobs.
- Durable background tasks ordered with active tasks first, including operation,
  timestamps, progress, output, failure, and cancellation.
- A live structured event timeline with search, failure filtering, pause and resume, and
  copy support.
- The most recent 500 retained events after daemon restart.

Events record category, name, level, message, duration, and task ID. Request payloads and
command environments are excluded. The unified log remains available through
`ed agent logs --last 1h` or the copyable command in Settings.

Useful CLI views are:

```text
ed agent status --json
ed agent jobs --json
ed agent events --json
ed agent tasks ls --json
ed agent logs --last 1h
```

## Ordered verification

Run checks in this order. A later stage assumes the prior ownership and data-integrity
gates passed.

### 1. Static contracts

```text
bun scripts/strip-comments.mjs --check
bun test scripts/*.test.js
swift format lint --strict --recursive Packages/Edith/Sources Packages/Edith/Tests
```

This catches unsupported source comments, script regressions, and formatting failures
before a long Swift build.

### 2. Scheduler and operation contracts

```text
swift test --package-path Packages/Edith --filter 'AgentOperationCatalogTests|JobSchedulerTests|AgentSchedulingIntegrationTests'
```

These suites verify that declared operations have handlers, overlapping requests share
one flight, cancellation discards late output, subscriber changes preserve active work,
disabled jobs remain stopped, and filesystem enqueue respects the ambient cadence.

### 3. Data retention contracts

```text
swift test --package-path Packages/Edith --filter 'UsageHistoryRetentionTests|UsageRefreshTests|ClipboardLargeHistoryTests'
bun test scripts/refresh-usage-jq.test.js scripts/usage-billing-archive.test.js scripts/usage-billing-envelopes.test.js
```

These suites cover exact history retention, concurrent publication, archive candidates,
numeric normalization, generated-link rejection, and clipboard archives larger than the
live capture limit.

### 4. Daemon integration fixtures

```text
python3 scripts/test-daemon-e2e.py
python3 scripts/test-clipboard-daemon-e2e.py
python3 scripts/test-attention-daemon-e2e.py
python3 scripts/test-attention-delivery-e2e.py
python3 scripts/test-machine-daemon-e2e.py
python3 scripts/test-site-audit-daemon-e2e.py
```

Each fixture uses an isolated data root and LaunchAgent label. It must prove that the
packaged client talks to the fixture daemon, that work continues without the UI process,
and that teardown leaves no owned processes.

### 5. Signed package verification

```text
make build
make verify-bundle
```

Verify the main executable, CLI launcher, nested login item, daemon, privileged helper,
resources, bundle identifiers, and strict code signatures. End-to-end fixtures should
clone this sealed app and record its source commit plus bundle digest before execution.

For usage retention, run two isolated variants in order:

1. A normal recovered baseline, new-day append, source pruning, daemon restart, repeated
   refresh, and original journal return.
2. An existing retention block with normalized numeric cost spellings, duplicate source
   rows, positional hours, the same restart sequence, and exact leaf comparison.

Each variant has five ordered assertions and must finish with no surviving daemon,
collector, runtime, helper, or CLI process.

### 6. Installed product

Install only after the sealed package and isolated fixtures pass. Wait for an active
usage collector to finish naturally, hold the three usage locks to prevent a new refresh,
replace the application atomically, release the locks, and let launchd restart `edithd`.

Then verify the installed bundle digest and signature, daemon registration and build,
the usage total and retained-day count, the Background Agent job table, the task list,
the live event timeline, and the nested menu bar helper. Confirm that no new crash report
appears for the helper.

## Resource rules

- One scheduler flight exists per job ID.
- Filesystem activity observes job cadence after the first run.
- Live polling exists only while a topic has subscribers.
- Optional extension jobs stop when their ability is disabled.
- Ambient jobs can pause on battery according to the user setting.
- Process runners have timeouts, output limits, cancellation, and process-group cleanup.
- Event history, task output, caches, and queues are bounded.
- SQLite uses WAL mode for short concurrent reads while the daemon owns writes.
- SwiftUI reads daemon snapshots and performs expensive formatting away from MainActor.

When adding a feature, prefer an existing scheduled job for periodic state, a durable task
for long user-triggered work, and a typed daemon operation for short shared mutations.
Add the operation to its catalog, expose job or task progress through the existing topics,
and extend the ordered integration fixture before adding a second worker path.
