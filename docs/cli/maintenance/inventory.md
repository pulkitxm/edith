# `ed maintenance inventory`

[`ed maintenance`](./README.md)

[The `ed` command line](../README.md)

```bash
ed maintenance inventory [--json] [--no-updates]
```

Lists regular app bundles directly inside `/Applications` and `~/Applications`. Apple apps, Edith, hidden entries, symlinks, and nested app paths are excluded. Homebrew cask update status appears only when one installed app name matches one outdated cask token exactly after punctuation is removed.

Pass `--no-updates` to skip launching Homebrew. `ls` and `list` are accepted aliases. JSON output is an array with `name`, `bundleID`, `version`, `path`, and nullable `update` fields.
