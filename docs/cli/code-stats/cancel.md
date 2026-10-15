# `ed code-stats cancel`

[`ed code-stats`](./README.md)

[The `ed` command line](../README.md)

```bash
ed code-stats cancel [--json]
```

Stops the refresh in progress, including its `git` processes. Repositories already counted stay cached and the previous report is kept. When nothing is running the command says so and changes nothing. `--json` prints the status after the request.
