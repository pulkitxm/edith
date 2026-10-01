# `ed seo start`

[`ed seo`](./README.md)

[The `ed` command line](../README.md)

```bash
ed seo start <id> [--lighthouse] [--no-lighthouse] [--wait] [--json]
```

Queues an audit of the selected pages. It uses the saved Lighthouse switch unless `--lighthouse` or `--no-lighthouse` is set. Without `--wait` the command returns once the run is queued. `--wait` blocks until the run finishes. At least one page has to be selected.
