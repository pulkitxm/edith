# `ed usage export`

Render Edith's local agent usage as branded, high resolution PNG cards. The
command reads `usage.json` directly and does not need the Edith app to be open.

```text
ed usage export [--card <card>]... [--output <path>] [--range <range>] [--source <source>]... [--machine <machine>]... [--json]
```

With no `--card`, the command exports highlights, activity calendar, daily
token rhythm and busiest day cards. Repeat `--card` to choose a subset. Valid
values are `highlights`, `activity`, `daily`, `busiest` and `all`.

`--output` accepts a directory. When exactly one card is selected, it can also
be the full destination PNG path. Without it, the images are written to the
current directory with timestamped filenames.

```bash
ed usage export
ed usage export --card activity --output ./shares
ed usage export --card highlights --card busiest --range month
ed usage export --card daily --output today.png --range today
ed usage export --json | jq -r '.files[]'
```

The image footer links to `github.com/pulkitxm/edith`. Exported cards never show
repository names, folder paths, chat titles or dollar costs.

When `--json` is present, stdout is one object:

```json
{
  "range": "all",
  "files": [
    "/work/edith-usage-highlights-2026-08-30-001500.png",
    "/work/edith-usage-activity-2026-08-30-001500.png"
  ]
}
```

The command exits 3 for an unknown card, 4 when the selected window has no
usage, and 1 when the destination cannot be created or written.

Related commands:

- [`ed usage`](./README.md), the rest of the usage group
- [`ed usage daily`](./daily.md), inspect the values behind the daily card
- [`ed usage refresh`](./refresh.md), collect fresh usage before exporting
- [All `ed` commands](../README.md)
