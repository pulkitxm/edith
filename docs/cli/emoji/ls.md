# `ed emoji ls`

Lists the emoji this Mac can render, in catalog order, with the same filters the
picker's search field applies.

Usage:

```
ed emoji ls [--frequent] [--search <text>] [--group <id>] [--limit <n>] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--frequent` | flag | off | Starts from your frequently used emoji instead of the whole catalog. |
| `--search <text>` | string | unset | Keeps only emoji whose name or keywords match, ranked by how well they match. |
| `--group <id>` | one of the category ids, for example `smileys-emotion` | unset | Keeps only emoji in that category. |
| `--limit <n>` | integer, 0 or more | `50` | Shows at most this many emoji. `0` shows all of them. |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments. `ls` also answers to `list`, and a bare
`ed emoji` runs this command.

The filters run in a fixed order: `--frequent` chooses the pool, `--group`
narrows it, `--search` filters and re-ranks what is left, and `--limit`
truncates last. `--limit` is checked before anything else, so a negative value
exits 2 with `--limit cannot be negative` on stderr and nothing on stdout. An
unknown `--group` exits 3 and lists the categories that exist on this Mac. There
is no such thing as an unknown `--search`: a query that matches nothing is an
empty result, not an error.

`--frequent` is the one filter that ignores `--limit` as an upper bound. It
returns at most `emojiFrequentCount` emoji, which defaults to 10 and is clamped
to 0 through 24, so `ed emoji ls --frequent --limit 50` prints 10 and
`ed config set emojiFrequentCount 0` makes it print nothing at all. Entries are
ordered by the decayed score described in [the group notes](./README.md), and
each stored character is mapped back to its base catalog entry, so a toned
insert of 👍🏽 is listed as 👍.

`--json` shape, an array with one object per emoji:

```json
[
  {
    "emoji": "🚀",
    "group": "travel-places",
    "keywords": [
      "launch",
      "rockets",
      "space",
      "travel"
    ],
    "name": "rocket",
    "skinTones": [],
    "unicodeVersion": 0.6
  },
  {
    "emoji": "👍️",
    "group": "people-body",
    "keywords": [
      "+1",
      "good",
      "hand",
      "like",
      "thumb",
      "yes"
    ],
    "name": "thumbs up",
    "skinTones": [
      "👍🏻",
      "👍🏼",
      "👍🏽",
      "👍🏾",
      "👍🏿"
    ],
    "unicodeVersion": 0.6
  }
]
```

`emoji` is the base character, never the toned one: your `emojiSkinTone` is not
applied here, and `skinTones` is where the five variants live, light first and
dark last. It is empty both for the emoji that have no tones and for the ones
whose tones do not all render on this Mac. `group` is the category id, the same
value `--group` takes, and it is `""` only if the catalog failed to load at all.
`name` and every entry in `keywords` are lowercase, which is what makes matching
predictable. `unicodeVersion` is a number, not a string, and whole versions print
without a decimal part, so you get `0.6`, `1`, `15.1` and `17`. An empty result
is an empty array rather than an error.

Examples:

```
ed emoji ls
ed emoji ls --search rocket
ed emoji ls --group food-drink --limit 10
ed emoji ls --frequent
ed emoji ls --search hand --json
ed emoji ls --limit 0 --json
```

Plain output is two spaces between the character and its name, and nothing else,
which is what makes it worth piping:

```
$ ed emoji ls --limit 5
😀  grinning face
😃  grinning face with big eyes
😄  grinning face with smiling eyes
😁  beaming face with smiling eyes
😆  grinning squinting face
```

Searching is literal and ranked, not fuzzy. Exact names win, then name prefixes,
then a prefix of any word in the name, then keywords:

```
$ ed emoji ls --search fire --limit 5
🔥  fire
🧑‍🚒  firefighter
🚒  fire engine
🎆  fireworks
🧨  firecracker
```

The query is trimmed, lowercased, underscores become spaces and colons are
dropped, so the three forms below are one query and all print the same row:

```
ed emoji ls --search ':thumbs_up:'
ed emoji ls --search 'thumbs up'
ed emoji ls --search 'Thumbs Up'
```

A query that normalises to nothing filters nothing, so `--search ":"` and
`--search "   "` behave like no `--search` at all.

Behaviour: `ls` only reads. It needs neither the Emoji Picker extension nor a
running Edith, and it never exits 4. With no matches and no `--json` it writes
`no emoji match` to stderr, or `no emoji used yet` when `--frequent` was passed,
leaves stdout empty and exits 0. With `--json` an empty result is `[]`, so a
caller can treat both as "nothing matched" without parsing prose. A list cut
short by `--limit` says nothing about it, so a default run stops at 50 silently.

## Where to go next

- [`ed emoji insert`](./insert.md), to type one of these
- [`ed emoji`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
