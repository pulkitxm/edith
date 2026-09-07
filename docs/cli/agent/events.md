# `ed agent events`

Reads the bounded, retained structured event timeline from the daemon over XPC.

```text
ed agent events [--json]
```

JSON contains event IDs, dates, levels, categories, names, messages, and optional
job IDs, task IDs and durations. A task ID connects queue, start, cancellation
request and final completion events. A cancellation request is recorded before
the task finishes stopping, so inspect its final state before assuming it stopped.

Events survive daemon restart. The in-app Background Agent pane shows the same
timeline with search, pause and expandable details.

- [`ed agent`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
