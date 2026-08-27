# `ed emoji`

`ed emoji` is Edith's emoji picker as a command: the panel the hotkey opens, the
catalog behind it, the skin tone it applies, and the frequency ledger that
decides what sits at the top of the grid. Reach for it when you want the picker
without leaving the keyboard, when a script needs to type an emoji into whatever
app is frontmost, or when you want to know which emoji this particular Mac can
actually draw.

The catalog is generated from `emojibase-data` and ships inside the app as
`emoji-catalog.json`: 1,914 emoji across nine categories. It is filtered on
load, against Apple Color Emoji on this Mac, so what `ed emoji ls` prints is
never the whole file and is not the same on every macOS version. See the notes
below for why that matters.

`ed emoji pick` and `ed emoji insert` ask the running menu bar app to do
something on the desktop, so both need the Emoji Picker extension on and Edith
running. `ls`, `tone` and `clear` are pure reads and writes against the shared
defaults suite (`com.pulkit.edith.shared`) and work with Edith closed and the
extension off. `ed emoji` with nothing after it is `ed emoji ls`.

## At a glance

| Command | What it does |
| --- | --- |
| `ed emoji` | Runs `ed emoji ls`, which is the default subcommand. |
| `ed emoji pick` | Asks the running menu bar app to open the picker panel, the same one `⌃⇧E` opens. |
| `ed emoji ls` | Lists the emoji this Mac can render, filtered by name, keyword, category or frequency. |
| `ed emoji insert <emoji>` | Types one emoji into the frontmost app and records the use. |
| `ed emoji tone <tone>` | Sets the default skin tone for the emoji that support one. |
| `ed emoji clear` | Forgets the frequently used ledger. |

`ed emoji list` is the same command as `ed emoji ls`.

## Commands

- [`ed emoji pick`](./pick.md)
- [`ed emoji ls`](./ls.md)
- [`ed emoji insert`](./insert.md)
- [`ed emoji tone`](./tone.md)
- [`ed emoji clear`](./clear.md)

## Exit codes

| Code | When this group produces it |
| --- | --- |
| 0 | The picker request was sent, the listing printed, an emoji was typed, the tone was written, or the ledger was cleared. Also an empty listing, and help. |
| 2 | `--limit` was negative (`--limit cannot be negative`), or the command line was wrong in ArgumentParser's own terms: an unknown flag, `--search`, `--group` or `--limit` with no value, a `--limit` value that is not an integer, or `insert` and `tone` with no argument at all. |
| 3 | Nothing in the catalog matches the argument to `insert`, `tone` was given something other than the six tone tokens, or `--group` named a category that does not exist. |
| 4 | `pick` or `insert` found the Emoji Picker extension off, or Edith's menu bar app closed. |

Nothing in this group exits 1. The two commands that reach the desktop are the
only ones that can exit 4, and the three that only touch defaults never do:

```
$ ed emoji pick
error: the Emoji Picker extension is off
hint: run `ed extensions enable emoji`, then retry
```

A not-found is always 3, and always carries the list or the next command to try:

```
$ ed emoji tone tan
error: no skin tone named tan
hint: tones: default, light, medium-light, medium, medium-dark, dark

$ ed emoji ls --group faces
error: no emoji category named faces
hint: categories: smileys-emotion, people-body, animals-nature, food-drink, travel-places, activities, objects, symbols, flags
```

## Notes and gotchas

- **The catalog is filtered by what this Mac can draw.** Every character in the
  bundled file is laid out once in Apple Color Emoji through CoreText and kept
  only if it ligates: a plain emoji has to come back as exactly one glyph, and a
  sequence joined with zero-width joiners has to come back as fewer glyphs than
  it has joined parts. An emoji macOS has never heard of does not fail to draw,
  it draws as its pieces, and that is precisely what the check rejects. So an
  older macOS silently has fewer emoji, and the ones it loses are the newest:
  the bundle carries 8 emoji at Unicode 17, 8 at 16, 21 at 15 and 28 at 15.1,
  all of which simply do not appear until the system font knows them. Nothing
  reports this as an error, so `ed emoji ls --search <something new>` printing
  `no emoji match` on one Mac and a row on another is expected.
- **Categories can disappear too.** Filtering runs before the category list is
  built, so a category left with nothing renderable is dropped entirely and its
  id stops being accepted by `--group`. The nine ids in the bundle are
  `smileys-emotion` (171), `people-body` (388), `animals-nature` (160),
  `food-drink` (131), `travel-places` (219), `activities` (85), `objects` (266),
  `symbols` (224) and `flags` (270). Pass the id, not the display name: `Smileys`
  is not `smileys-emotion` and exits 3.
- **Skin tones are all or nothing per emoji.** About 330 of the catalog's emoji
  have the five toned variants. If any one of those five does not render, the
  emoji keeps its place in the list but loses all five, and its `skinTones`
  array in `--json` comes back empty. An emoji with no tone support at all is
  unaffected by the default tone: `character(tone:)` falls back to the base
  character, so setting a dark default tone changes 👋 and leaves 🚀 alone.
- **The frequency ledger is a stored value, not a setting.** It lives at the
  `emojiUsage` key of the `com.pulkit.edith.shared` defaults suite as a
  JSON-encoded list of `{character, count, lastUsedAt}`. So
  `ed config ls --group emoji` lists the seven `emoji` settings and never the
  ledger, `ed config unset` has nothing to unset here, and neither
  `ed config export` nor Edith's settings backup carries your habits to another
  Mac. `ed emoji clear` is the only way to empty it from the command line.
- **Frequency is decayed, not counted.** Each entry scores
  `count * 0.5^(ageDays / 21)`, so an emoji you used twenty times last quarter
  loses to one you used four times this week. Ties break by most recent use, then
  by the character itself. The ledger holds at most 200 entries; recording the
  201st drops the lowest scoring one, never the one you just used.
- **`--frequent` is capped by a setting, not by `--limit`.** It shows at most
  `emojiFrequentCount` emoji, which defaults to 10 and is clamped to 0 through
  24, which is also exactly what the picker pins above the grid.
  `ed emoji ls --frequent --limit 50` still prints 10, and
  `ed config set emojiFrequentCount 0` makes `--frequent` print nothing however
  full the ledger is. `--limit` can only shorten that list further.
- **`--frequent` reports base characters.** Stored characters are mapped back to
  their catalog entry, and a toned variant maps to the base emoji, so an insert
  of 👍🏽 shows up as 👍. If the ledger holds both 👍 and 👍🏽 they map to the same
  entry and the same row appears twice.
- **The filters run in a fixed order.** `--frequent` chooses the pool, `--group`
  narrows it, `--search` filters and re-ranks what is left, and `--limit`
  truncates last. Because searching re-ranks, `--frequent --search hand` comes
  back in relevance order, not in frequency order.
- **Search normalises before it matches.** The query is trimmed, lowercased,
  underscores become spaces and colons are removed, so `:thumbs_up:`,
  `thumbs up` and `Thumbs Up` are one query. A query that normalises to nothing,
  such as `--search ":"` or `--search "   "`, filters nothing rather than
  erroring. Matching is literal, never fuzzy: a typo matches nothing.
- **Ranking is a fixed ladder.** Exact name, then name prefix, then a prefix of
  any word in the name, then exact keyword, then keyword prefix, then name
  substring, then keyword substring. Within one rung, catalog order wins, which
  is Unicode order inside a category. That is why `--search fire` gives 🔥 first
  and then firefighter, fire engine, fireworks and firecracker.
- **`ls` never applies your default tone.** It always prints base characters and
  exposes the variants through the `skinTones` array. Only `insert` and the
  picker itself apply `emojiSkinTone`.
- **Hexcodes must be the whole sequence.** 517 of the 1,914 characters carry a
  variation selector and 249 contain a zero-width joiner, and the lookup is an
  exact character match. `ed emoji insert 1F600` finds 😀, but thumbs up is
  stored as `1F44D-FE0F`, and `1F44D` on its own matches nothing, falls through
  to the name search, finds nothing there either and exits 3. Parts are joined by
  a hyphen or a space and are case insensitive, so `1f1ee-1f1f3` is 🇮🇳.
- **`tone` and `clear` are not gated.** Neither checks the extension and neither
  needs the app, because both only write to shared defaults. `ed emoji tone dark`
  is `ed config set emojiSkinTone 5` with a name in front of the number, and the
  setting is an integer 0 through 5, so `ed config set emojiSkinTone 9` is
  rejected by the config catalog's own range check.
- **Both writes post `settingsChanged`.** A running picker re-reads its ledger
  and its tone on that notification, so `ed emoji clear` empties the frequently
  used row of an open panel straight away, and `ed emoji tone medium` repaints
  it. The post is fire and forget, so neither command fails when nothing is
  listening.
- **Typing is synthetic key events.** `insert` hands the character to the app,
  which posts a key down and a key up carrying the Unicode string to the session
  event tap. That means Edith wants Accessibility, and it means an app with
  secure keyboard entry on, such as a password field, will ignore the event and
  leave you with nothing typed and a recorded use.
- **There is no per-emoji forget from the command line.** `clear` empties the
  ledger whole, and the only way to drop a single emoji from the frequently used
  row is the panel's own context menu.
- **`--help` works on the group and on all five verbs**, prints on stdout and
  exits 0.
- **Completion knows the typed arguments.** `ed emoji tone <TAB>` offers the six
  tone tokens, `ed emoji ls --group <TAB>` offers the category ids that survived
  filtering on this Mac, and `ed emoji insert <TAB>` offers your frequently used
  emoji, which means it offers nothing until you have inserted something.

## Where to go next

- [`ed color`](../color/README.md), the other picker Edith puts on a hotkey
- [`ed extensions`](../extensions/README.md), to turn the emoji picker on or off
- [`ed config`](../config/README.md), for the seven `emoji` settings behind it
- [`ed permissions`](../permissions/README.md), for the Accessibility access that typing wants
- [All `ed` commands](../README.md)
