# `ed attention breakdown`

Groups active time by one dimension, such as the app or site, the page or window
title, the Edith machine or agent you were looking at, a GitHub repository, a
YouTube channel or a search.

```
ed attention breakdown [--by <dimension>] [--range <window>] [--limit <count>] [--json]
```

`--by` accepts `app`, `title`, `url`, `page`, `machine`, `agent`, `project`,
`repo`, `section`, `channel`, `group`, `search` and `doc`. It defaults to `app`.

- `page`, `machine`, `agent` and `project` come from the Edith app itself. They say
  which Edith page was open and, on Sessions, which agent on which machine had
  focus.
- `repo`, `section`, `channel`, `group`, `search` and `doc` come from the browser
  extension. Each is a GitHub repository, a site section such as a pull request or
  a YouTube watch page, a creator or subreddit, a tab group, a search query or a
  GitHub issue or pull request title.

The default range is `today` and the default limit is 25 rows. Pass `--limit 0`
for every row the summary keeps, at most 80 per dimension.

Each JSON row has the `key`, `durationSeconds`, `categorySeconds` keyed by
category ID, the number of keystrokes, clicks and scrolls as `interactions`, and up
to three `entities` that the time belonged to.

## Where to go next

- [CLI index](../README.md)
- [`ed attention summary`](./summary.md)
- [`ed attention agents`](./agents.md)
