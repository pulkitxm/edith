# `ed seo pages`

[`ed seo`](./README.md)

[The `ed` command line](../README.md)

```bash
ed seo pages <id> [--refresh] [--all] [--none] [--only <url>...] [--add <url>...] [--remove <url>...] [--json]
```

Prints the discovered pages and which ones are selected. When the list is empty, or with `--refresh`, it crawls the site and selects pages that were not in the previous list. Pass one of `--all`, `--none`, `--only`, `--add`, or `--remove` to change that selection. URLs must already be in the discovery list. JSON is the saved draft.
