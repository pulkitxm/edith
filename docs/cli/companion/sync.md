# `ed companion sync`

Pulls recent data from a live connector. GitHub writes independent activity
observations; Notion renders authored pages and ingests them as episodes.

Usage:

```
ed companion sync <github|notion> [--full] [--json] [--endpoint <url>]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<connector>` | `github` or `notion` | required | Which live connector to sync. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | resolution order | Uses this Companion API base URL. |
| `--full` | flag | off | For Notion, ignores the saved watermark and reconciles every page. GitHub ignores this flag. |

GitHub `--json` shape:

```json
{
  "eventsFetched": 87,
  "observationsInserted": 42
}
```

`eventsFetched` counts the GitHub events read this run;
`observationsInserted` counts new observations. Re-running immediately inserts
nothing because every observation carries a dedupe key.

Notion `--json` shape:

```json
{
  "episodesIngested": 6,
  "fullScan": false,
  "pagesSeen": 9,
  "pagesWritten": 6,
  "watermark": "2026-08-16T08:10:00+00:00"
}
```

Notion renders changed pages to Markdown under `notion/<page-id>.md` in the
vault, ingests them through the normal Markdown path, and then starts indexing.
Without `--full`, the saved `notion.watermark` stops the scan once it reaches
pages already seen. `--full` rereads every page, but content-hash deduplication
still prevents duplicate episodes.

Examples:

```
$ ed companion sync github
fetched 87 events, 42 new observations

$ ed companion sync notion --full
saw 103 pages, wrote 98, 6 new episodes
```

Behaviour: GitHub reads up to three pages of the authenticated user's events.
Push events become one `commit` observation per commit; pull request, issue and
review events each become one observation. Notion uses its search API, follows
pagination, renders supported blocks, and paces calls to respect the API rate.
Tokens can come from the backend environment or `ed companion connectors set`.
Without the selected connector's token the backend answers 412 and the command
fails with exit 1. An upstream connector failure answers 502 and also exits 1.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
