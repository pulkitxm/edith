# `ed companion connectors`

Companion connectors bring in two kinds of material. GitHub and the file imports
produce observations: traces of what you did that do not come from you describing
yourself. Notion is authored memory, so its pages go through ordinary Markdown
ingestion and become episodes instead. Corroboration and calibration rely on the
observation side of that boundary.

Usage:

```
ed companion connectors [show] [--json] [--endpoint <url>]
ed companion connectors set [--github <token>] [--notion <token>] [--json]
                            [--endpoint <url>]
ed companion connectors import <calendar|music|youtube> <file.json> [--json]
                               [--endpoint <url>]
```

`ed companion connectors show` (also the bare default) says which connectors have a
token and prints only the last four characters of each. The token itself is never
returned.

`ed companion connectors set` stores a token on the companion, in the same settings
table as the reasoner key, and hot-swaps it into the running service. Nothing is
written to the CLI's local configuration and no restart or `.env` edit is needed.
Pass an empty value to clear one. The same fields are in the app under Settings.

`set` requires at least one of `--github` or `--notion`. In a shell, clearing
means passing an explicit empty argument such as `--github ''`; omitting an
option leaves that token unchanged. `--json` returns the masked detail strings,
not either token.

| Connector | What it gives you |
| --- | --- |
| GitHub | Commits, pull requests, reviews and their timestamps. The single best ground truth you have, and the commit-hour distribution is a sleep and work-rhythm sensor for free. |
| Notion | Pages synced to markdown on disk, then ingested by the normal markdown path. |
| Calendar | Meeting density, back-to-backs, and what got moved. Rescheduling is a decent avoidance signal. |
| Music | Play patterns: repeats, time of day, comfort listening. Never a mood label. |
| YouTube | Watch history from a Takeout export. Rabbit-hole depth at 2am says more than the topics. |

`ed companion connectors import` is for the three with no live API worth using.
Calendar and music can be exported from whatever you use, YouTube comes from Google
Takeout, and each import is idempotent, so re-running against a fresh dump only adds
what is new.

The import file must be readable local JSON. Human output reports entries read,
new observations and skipped entries. JSON output is
`{source,entriesRead,observationsInserted,skipped}`. Unsupported source names
and malformed export shapes are rejected by the backend.

On music specifically, only measurements are stored: which track, when, how often.
No valence, no energy, no mood. "Sad songs means sad" is a weak inference, and a
label built on it would embarrass itself; whether your play patterns correlate with
anything you actually said is for the nightly job to find out, not for the connector
to assume.

## Where to go next

- [`ed companion observations`](./observations.md), what the connectors recorded
- [`ed companion sync`](./sync.md), pulling GitHub and Notion
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
