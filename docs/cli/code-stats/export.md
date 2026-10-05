# `ed code-stats export`

[`ed code-stats`](./README.md)

[The `ed` command line](../README.md)

```bash
ed code-stats export [--range 30d|90d|1y|all] [--card highlights|languages|rhythm|all] [-o <directory|file.png>] [--clipboard] [--json]
```

Renders the report the last refresh stored as branded, high resolution PNG cards, the same ones the Share button on the Code Stats page makes. The cards are mostly numbers, with no charts beyond a thin share bar per language.

| Card | What it shows |
| --- | --- |
| `highlights` | Commits, lines authored, net lines, active days, longest streak and lines per active day, with the change against the previous period |
| `languages` | The top six languages by lines authored, with each one's share |
| `rhythm` | Your busiest weekday, peak hour and biggest day, with current and longest streak |

Nothing that names a repository, an author, a commit or a path is drawn or written. Every figure is a total across all repositories.

`--range` picks 30 days (the default), 90 days, a year or all time. `--card` is repeatable and defaults to all three cards. `-o` is a directory, or a `.png` path when exactly one card is selected. Files are named `edith-code-stats-<card>-<timestamp>.png` and go in the current directory when `-o` is not given. `--clipboard` also copies the first card.

`--json` prints the range, the files written and the metrics behind the cards, so a script or an agent can read the numbers without opening the images. For example, abridged:

```json
{
  "files": ["/Users/you/edith-code-stats-highlights-2026-10-05-141500.png"],
  "metrics": {
    "activeDays": 61,
    "commits": 412,
    "linesAuthored": 38120,
    "longestStreak": 14,
    "rangeLabel": "Last 90 days"
  },
  "range": "90d"
}
```

Exits 3 when no refresh has finished yet or a card name is unknown, 4 when the range holds no code activity, and 2 for a range that is not offered. It reads the stored report and does not refresh anything.
