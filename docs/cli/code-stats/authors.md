# `ed code-stats authors`

[`ed code-stats`](./README.md)

[The `ed` command line](../README.md)

```bash
ed code-stats authors [--json]
```

Reads every repository in the mirror and lists the most frequent author name and email pairs with their commit counts, marking the ones your identities already count. Use it to find the old emails and machine names you committed under, then add them with `ed code-stats identity add`. The folder has to be ready and `git` installed.
