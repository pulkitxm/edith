# `ed maintenance update`

[`ed maintenance`](./README.md)

[The `ed` command line](../README.md)

```bash
ed maintenance update [id ...] [--concurrency 2] [--retries 1] [--yes] [--json]
```

Builds a batch from the named update IDs, or every visible update when IDs are omitted. Without `--yes`, it only prints the reviewed plan. Confirmed work runs at most four items together, retries at most three times, supports process cancellation, and saves one result per item. Feed-based apps open their own updater.
