# `ed companion nightly`

Runs the whole nightly pipeline immediately: GitHub sync, indexing, claim
extraction, corroboration and reflection. The command returns when the pipeline
finishes, which can take minutes on a slow reasoner.

Usage:

```
ed companion nightly [--json] [--endpoint <url>]
```

`--json` shape: `{"runId": "<uuid>"}`. Inspect the recorded steps with
`ed companion runs`.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
