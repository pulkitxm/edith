# `ed code-stats audit`

[`ed code-stats`](./README.md)

[The `ed` command line](../README.md)

```bash
ed code-stats audit [--json]
```

Explains the report. It compares the raw commits and lines in the mirror with what the report counts, and lists each reason something was left out or added: bulk imports above the bulk threshold, formatter runs, generated files, data and config, markup and style, docs, whitespace-only lines, duplicate content found in more than one repository, commits from branches already squash-merged into the default branch, agent-assisted commits in repositories you own, and commits where you are only a co-author. It also lists repositories that copy another one and authors that look like you but are not in your identities, so you can add them with `ed code-stats identity add`. It reads what the last refresh stored and does not change anything.
