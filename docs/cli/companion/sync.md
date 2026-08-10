# `ed companion sync`

Pulls a connector's recent activity into the observations table.

Usage:

```
ed companion sync <connector> [--json] [--endpoint <url>]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<connector>` | `github` | required | Which connector to sync; only `github` exists so far. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | environment or local default | Uses this Companion API base URL. |

`--json` shape:

```json
{
  "eventsFetched": 87,
  "observationsInserted": 42
}
```

`eventsFetched` counts the GitHub events read this run; `observationsInserted` counts the observations that were new. Re-running immediately inserts nothing because every observation carries a dedupe key.

Examples:

```
$ ed companion sync github
fetched 87 events, 42 new observations
```

Behaviour: the companion reads up to three pages of the authenticated user's GitHub events with the token in its `GITHUB_TOKEN` environment variable. Push events become one `commit` observation per commit; pull request, issue and review events each become one observation. Without a configured token the companion answers 412 and the command fails with exit 4.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
