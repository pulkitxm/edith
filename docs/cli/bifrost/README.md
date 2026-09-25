# `ed bifrost`

`ed bifrost` is Edith's launcher as a command: the bar the shortcut opens, the
application index behind it, and the two answers it gives without leaving the
keyboard, a sum and a unit conversion. Reach for it when you want the bar from a
script, when you want to know which applications Edith can actually see, or when
you want the same answer the bar would show without opening anything.

The index is built by scanning the application folders on this Mac and is cached
at `~/Library/Caches/Edith/bifrost-index.json`. It is not a live view of the
disk: an application installed after the last scan is invisible until the index
is rebuilt, which the bar does on first use and `ed bifrost reindex` does on
demand.

`ed bifrost open` and `ed bifrost reindex` ask the running menu bar app to do
something on the desktop, so both need the Bifrost extension on and Edith
running. `ls`, `calc`, `convert` and `clear` work with Edith closed: `ls` reads
the cache, `calc` and `convert` are pure computation and are not gated on the
extension at all, and `clear` only writes the shared defaults suite
(`com.pulkit.edith.shared`). `ed bifrost` with nothing after it is
`ed bifrost ls`.

## At a glance

| Command | What it does |
| --- | --- |
| `ed bifrost` | Runs `ed bifrost ls`, which is the default subcommand. |
| `ed bifrost open [query]` | Asks the running menu bar app to open the bar, the same one `⌥space` opens. |
| `ed bifrost ls` | Lists the indexed applications, optionally ranked against a query exactly as the bar ranks them. |
| `ed bifrost calc <expression>` | Evaluates an expression and prints the number. |
| `ed bifrost convert <sentence>` | Converts between units and prints both sides. |
| `ed bifrost reindex` | Asks the running app to scan the application folders again. |
| `ed bifrost clear` | Forgets the frequently opened ledger. |

`ed bifrost list` is the same command as `ed bifrost ls`.

## Commands

- [`ed bifrost open`](./open.md)
- [`ed bifrost ls`](./ls.md)
- [`ed bifrost calc`](./calc.md)
- [`ed bifrost convert`](./convert.md)
- [`ed bifrost reindex`](./reindex.md)
- [`ed bifrost clear`](./clear.md)

## Exit codes

| Code | When this group produces it |
| --- | --- |
| 0 | The bar was requested, the listing printed, the expression evaluated, the conversion resolved, the rebuild was requested, or the ledger was cleared. Also an empty listing, and help. |
| 2 | `--limit` was negative, or the command line was wrong in ArgumentParser's own terms: an unknown flag, `--search` or `--limit` with no value, a `--limit` value that is not an integer, or `calc` and `convert` with no argument at all. |
| 3 | Nothing is indexed yet, the expression is not one Bifrost can evaluate, or the sentence is not a conversion it understands. |
| 4 | `open` or `reindex` found the Bifrost extension off, or Edith's menu bar app closed. |

Nothing in this group exits 1. The two commands that reach the desktop are the
only ones that can exit 4:

```
$ ed bifrost open
error: the Bifrost extension is off
hint: run `ed extensions enable bifrost`, then retry
```

A not-found is always 3, and always carries the next command to try:

```
$ ed bifrost ls
error: no applications are indexed yet
hint: run `ed bifrost reindex` with Edith running

$ ed bifrost calc "safari"
error: safari is not an expression Bifrost can evaluate
hint: try a sum such as `ed bifrost calc "2 + 2"`
```

## The extra sources

The bar always searches the application index, the calculator, unit and currency
conversion, clipboard history and file search. Everything else is a switch, off
or on in Settings, Extensions, Bifrost, and readable from the command line:

```sh
ed config ls --group bifrost --json
ed config set bifrostSourceOpenWindows true
```

| Source | Key | On by default | What it adds |
| --- | --- | --- | --- |
| Quicklinks | `bifrostSourceQuicklinks` | yes | Your saved links, searches and deeplinks |
| Snippets | `bifrostSourceSnippets` | yes | Reusable text, pasted into the app you were typing in |
| Shell commands | `bifrostSourceShellCommands` | yes | Named scripts run through your login shell |
| Apple Shortcuts | `bifrostSourceAppleShortcuts` | yes | What `shortcuts list` reports, run with `shortcuts run` |
| Window management | `bifrostSourceWindowActions` | yes | Twenty-seven Rectangle-style actions on the front window |
| System actions | `bifrostSourceSystemActions` | yes | Lock, sleep, appearance, trash, eject, restart, shut down |
| Running apps | `bifrostSourceRunningApplications` | yes | Switch to or quit an app that is open now |
| Open windows | `bifrostSourceOpenWindows` | no | Jump to an open window by its title |

Window management, open windows and pasting a snippet need Accessibility.
Without it the window actions do nothing and a snippet is only copied.

```sh
ed permissions request accessibility
```

The five destructive system actions — log out, restart, shut down, empty trash
and quit all apps — raise a confirmation before anything happens.

### Quicklinks, snippets and commands

The three you write yourself live in the shared defaults suite as JSON, at
`bifrostQuicklinks`, `bifrostSnippets` and `bifrostShellCommands`, so they
travel with a settings backup and can be scripted. Each takes placeholders:

| Placeholder | Becomes |
| --- | --- |
| `{query}` | What you typed after the keyword |
| `{clipboard}` | The current clipboard text |
| `{selection}` | The selection, falling back to the clipboard |
| `{date}` | Today, `yyyy-MM-dd`, or `{date:EEEE}` for your own format |
| `{time}` | Now, `HH:mm`, or `{time:HH.mm.ss}` |
| `{uuid}` | A fresh UUID |

Give one a keyword and it becomes a prefix: type `gh edith` and the bar runs the
quicklink keyed `gh` with `edith` as `{query}`, skipping every other result. A
keyword on its own is just a search. Values going into a web URL are
percent-encoded, and snippets and file quicklinks get them as typed. Shell
commands never see the text itself: each placeholder becomes a quoted reference
to an environment variable (`EDITH_BIFROST_1`, `EDITH_BIFROST_2`, ...) holding
the value, so clipboard text such as `; rm -rf ~` stays data whether the
placeholder sits bare, inside double quotes or inside single quotes.

## Notes and gotchas

- **The index is a cache, not a search.** Scanning walks `/Applications`,
  `/System/Applications`, `/System/Library/CoreServices/Applications`,
  `/System/Cryptexes/App/System/Applications` and `~/Applications`, three
  directory levels deep, and never descends into a bundle. An application
  somewhere else, a `.prefPane`, or a bundle nested more deeply than three
  folders simply is not there. At most 4,000 bundles are kept.
- **Names come from the bundle, not the file name.** `CFBundleDisplayName`
  wins, then `CFBundleName`, then the file name without `.app`. That is why an
  application whose folder is named `com.example.thing.app` can still list as
  `Thing`, and why searching for the file name may find nothing.
- **Ranking is the bar's ranking.** `ed bifrost ls --search` runs the same
  matcher the panel does, so what it prints in order is what the bar would show
  in order, including the frequency boost from your own ledger. Without
  `--search`, `ls` prints the index in alphabetical order and ignores the
  ledger entirely.
- **Matching is a subsequence that has to start a word.** Every letter of the
  query has to appear in the name in order, so `gc` finds Google Chrome and
  `vsc` finds Visual Studio Code, while `safz` finds nothing. The first letter
  also has to land on the start of a word, which is what stops `aaa` from
  matching three scattered letters in Edith Panel: `chrome` finds Google
  Chrome, `hrome` finds nothing. A word starts after a space, a hyphen, an
  underscore, a dot or a slash, and at a case or digit boundary, so `term`
  finds iTerm. Word starts and runs of adjacent letters score higher than
  scattered letters, an exact name beats a prefix, and a shorter name wins a
  tie.
- **The ledger is a stored value, not a setting.** It lives at the
  `bifrostUsage` key of the shared defaults suite as a JSON-encoded list of
  `{target, count, lastUsedAt}`, so `ed config ls --group bifrost` lists the
  nineteen `bifrost` settings and never the ledger. `ed bifrost clear` is the only
  way to empty it from the command line.
- **Frequency is decayed, not counted.** Each entry scores
  `count * 0.5^(ageDays / 14)`, so something you opened thirty times last month
  loses to something you opened five times this week. The ledger holds at most
  300 entries and the boost it contributes is capped, so frequency breaks ties
  between comparable matches rather than overriding the match itself.
- **An answer gets a card, not a row.** A sum, a unit conversion or a currency
  conversion renders as a two-sided card: what you asked on the left, the answer
  on the right, both sides named underneath. Return copies the answer exactly as
  it does from a row.
- **Currency needs a rate, so it needs the network.** Typing `48k usd in inr`
  converts through the European Central Bank's daily reference rates, which
  Edith fetches from `ecb.europa.eu` at most once every six hours and caches at
  `~/Library/Caches/Edith/bifrost-rates.json`. The request carries nothing but
  itself, there is no key and no account, and with no cache and no network a
  currency query simply produces no answer rather than an error. The card says
  how old the rate is. Amounts understand `k`, `m` and `b`, so `48k` is 48,000.
- **Commands sit next to applications.** The bar also lists Edith's own
  abilities as commands: the clipboard history, file search, the emoji picker,
  the colour picker, the Edith panel and a rebuild of this index. A command only
  appears while the ability behind it is enabled, and it matches on what it does
  as well as its name, so `paste` finds the clipboard history.
- **The clipboard and file search open inside the bar.** Choosing either turns
  the bar into that view rather than opening another window: entries on the
  left grouped by the day you copied them, what is selected on the right with
  its preview and its details, a scope menu at the top right, and escape to go
  back.
- **File search has three dials.** Names or Contents chooses what is searched,
  a kind narrows it to images, documents or code, and the scope picks where:
  your home folder, Desktop, Documents, Downloads, everywhere, or one of the
  machines you have configured. Contents searching and any narrowed kind go
  through ripgrep when it is installed, an empty query lists what you used this
  week through Spotlight's `mdfind`, and everything falls back to `mdfind` when
  ripgrep is missing. A machine scope runs the same ripgrep query over SSH and
  lists what it finds there; those rows name their machine and carry no local
  preview.
- **The bar learns what you meant.** Picking a result records the query you
  typed as well as what you opened, so once you have opened WhatsApp from `w`,
  `w` puts it first next time. A lesson from a longer query still helps a
  shorter prefix of it, it never leaks into an unrelated query, and it decays
  on the same fourteen-day half-life as everything else, so a one-off choice
  fades rather than sticking forever.
- **Dragging the bar makes its position yours.** The bar is movable by its
  background; dashed guides appear across the screen while you drag, and
  letting go writes the position and switches `bifrostPopupAt` to
  `lastPosition`, so it opens where you left it until you choose another mode.
- **The field is an ordinary text field.** ⌘A, ⌘C, ⌘V, ⌘X, ⌘Z and ⇧⌘Z all work,
  which a menu bar app has to arrange for itself because it has no Edit menu.
- **Hold command to number the rows.** The `⌘1` to `⌘9` chips appear only while
  command is down, and pressing the number runs that row. The bar itself opens,
  grows and dismisses the way Spotlight does: the top edge stays where it is and
  the list grows downward in about a fifth of a second.
- **Return runs, `⌥`-return copies.** Return opens an application and puts an
  answer on the pasteboard; holding option copies whichever row is selected,
  including an application's path. Only the first of those counts as opening
  something, so only the first moves the frequency ledger.
- **Only the bar records use.** Opening an application from `ed` does not exist
  as a command, and `ls` never records anything, so the ledger only ever moves
  when you pick something in the panel.
- **`calc` and `convert` are not gated.** Neither checks the extension and
  neither needs the app, because both are pure computation on their argument.
  That also makes them the fastest way to check what the bar would answer.
- **Quote the argument.** Both `calc` and `convert` take a single positional
  argument, and both `*` and spaces mean something to your shell, so
  `ed bifrost calc "12 * 8"` and `ed bifrost convert "12 km in miles"` need the
  quotes. Without them the shell splits or globs the expression and the command
  exits 2 or 3.
- **`open` toggles rather than shows.** A second `ed bifrost open` while the bar
  is up closes it again, unless a query is passed, which always reopens the bar
  with that text in the field. Worth knowing before putting the command behind a
  repeating trigger.
- **`reindex` is fire and forget.** It asks the running app to scan and returns
  straight away; it does not wait for the scan and does not report how many
  applications were found. Read the result with `ed bifrost ls --json` once the
  scan has had a moment, or from the Bifrost settings pane, which shows the
  count.
- **`--help` works on the group and on all six verbs**, prints on stdout and
  exits 0.
- **Completion knows the typed arguments.** `ed bifrost open <TAB>` offers the
  names of the first 200 indexed applications, which means it offers nothing
  until the index exists.

## Where to go next

- [`ed emoji`](../emoji/README.md), the other bar Edith puts on a hotkey
- [`ed apps`](../apps/README.md), for the applications that are actually running
- [`ed extensions`](../extensions/README.md), to turn Bifrost on or off
- [`ed config`](../config/README.md), for the seven `bifrost` settings behind it
- [All `ed` commands](../README.md)
