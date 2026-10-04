# `ed code-stats identity`

[`ed code-stats`](./README.md)

[The `ed` command line](../README.md)

```bash
ed code-stats identity list [--json]
ed code-stats identity add <value> [--json]
ed code-stats identity remove <value> [--json]
```

Identities decide which commits are yours. A value with an `@` is an author email and matches exactly, ignoring case. Any other value is a fragment that matches when it appears in the author name or email. When the list is empty, the next refresh fills it with your GitHub login and verified emails.

`ed code-stats identity list` prints the identities, emails first; `ls` is an alias and `list` is the default. `ed code-stats identity add` adds one and reports `changed: false` when it was already there. `ed code-stats identity remove` (also `rm`) removes one, and exits 3 when it is not listed. Changing identities makes the next refresh recount every repository.
