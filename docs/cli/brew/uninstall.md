# `ed brew uninstall`

[`ed brew`](./README.md)

[The `ed` command line](../README.md)

```bash
ed brew uninstall NAME [--kind formula|cask] [--yes] [--json]
```

Without `--yes`, prints the exact package and kind and changes nothing. With `--yes`, validates the package token again and performs the bounded uninstall. JSON previews report `applied: false` and `changed: false`; applied results include the retained output tail.
