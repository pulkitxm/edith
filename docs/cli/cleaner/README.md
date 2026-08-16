# `ed cleaner`

`ed cleaner` is the disk cleaner: it measures the developer caches and build
output sitting in your home directory, and moves what it finds to the Trash.
Reach for it when a laptop is out of space and you would rather delete a
rebuildable cache than a file you care about.

Everything here runs inside the `ed` process. Scanning walks your own home
directory with your own file permissions, cleaning calls `trashItem` directly,
and nothing is asked of the app, so every verb works whether or not Edith is
running and none of them can exit 4.

The two things to know before you type anything: `ed cleaner clean` has no
notion of a selection, so it moves everything the same scan found rather than
the subset the Cleaner card would have ticked, and moving to the Trash does not
free the space until you empty the Trash.

## At a glance

| Command | What it does |
| --- | --- |
| `ed cleaner` | Runs `ed cleaner scan`, which is the default subcommand. |
| `ed cleaner scan` | Measures what could be reclaimed, per category, and prints a total. Reads only. |
| `ed cleaner categories` | Lists the eleven fixed caches the cleaner knows, and what each one holds. `--json` adds the paths. |
| `ed cleaner clean` | Re-scans, then moves every item found to the Trash. Does nothing without `--yes`. |
| `ed cleaner drives` | Lists the mounted volumes, their capacity and whether they are external. |

`ed cleaner ls` is the same command as `ed cleaner categories`.

## What each category removes

A category is an id you pass to `--category`. There are nineteen of them in two
families, and the difference matters: the eleven fixed caches are found by
looking at known paths under your home directory, and the eight project
categories only exist when you sweep a folder with `--root`.

The fixed caches, in the order `ed cleaner categories` prints them. "On by
default" is the Cleaner card's initial checkbox, and `ed cleaner clean` ignores
it.

| Id | What is removed | On by default | What it costs you |
| --- | --- | --- | --- |
| `derivedData` | Everything under `~/Library/Developer/Xcode/DerivedData`: build intermediates, module caches, index stores and build logs, for every project Xcode has ever opened | yes | The next build of each project is a full one, and Xcode reindexes |
| `swiftpm` | `~/Library/Caches/org.swift.swiftpm`, the shared Swift Package Manager cache of package checkouts and manifests | yes | Packages are fetched from the network again on the next resolve |
| `npm` | `~/.npm/_cacache`, npm's content-addressed tarball and index cache | yes | Tarballs are re-downloaded on the next install |
| `yarn` | `~/Library/Caches/Yarn` | yes | Re-downloaded on the next install |
| `bun` | `~/.bun/install/cache` | yes | Re-downloaded on the next install |
| `pip` | `~/Library/Caches/pip`, the wheel and HTTP cache | yes | Wheels are re-downloaded on the next install |
| `homebrew` | `~/Library/Caches/Homebrew`, the downloaded bottles and source tarballs. Installed formulae live elsewhere and are untouched | yes | The next `brew install` or upgrade downloads again |
| `playwright` | `~/Library/Caches/ms-playwright`, the browser binaries Playwright drives | no | The next test run downloads several hundred megabytes of browsers before it can start |
| `puppeteer` | `~/.cache/puppeteer`, the Chromium builds Puppeteer downloads | no | The next run downloads Chromium again |
| `claudeCode` | `~/.claude/debug` and `~/.claude/shell-snapshots` | yes | Nothing you would miss. Transcripts, projects and settings elsewhere under `~/.claude` are not touched |
| `claudeMcp` | `~/Library/Caches/claude-cli-nodejs`, MCP server logs, which grow without bound | yes | Nothing, past logs are gone |

The project categories match a directory by its **name**, anywhere under a
folder you pass to `--root`. There is no check that a project surrounds it, so
a directory you happen to have called `target` or `Pods` is swept along with
the real ones.

| Id | Directory names matched | What is removed | What it costs you |
| --- | --- | --- | --- |
| `nodeModules` | `node_modules` | The whole dependency tree, including anything patched in place | An install restores it, network permitting |
| `pycache` | `__pycache__` | Compiled bytecode caches | Nothing, Python regenerates them |
| `pyvenv` | `.venv` and `venv` | The entire virtual environment: the interpreter symlinks, every installed package, and any scripts you dropped in `bin` | Recreated from your requirements, if you have a lockfile |
| `rustTarget` | `target` | Cargo and Maven build output, which is usually the largest thing in a Rust checkout | A full rebuild |
| `gradle` | `.gradle` | Per-project Gradle caches and daemon state | A slower next build |
| `pods` | `Pods` | The CocoaPods checkout directory. Your `Podfile` and `Podfile.lock` are not touched | `pod install` restores it |
| `nextBuild` | `.next` | The Next.js build directory | A rebuild |
| `turbo` | `.turbo` | The Turborepo local task cache | Cache misses on the next run |

Both families are destructive in the same way and to the same degree: the item
is moved to the Trash whole, and the Trash keeps occupying the disk until you
empty it. Nothing here is deleted in place, so a mistake is recoverable from
Finder until then.

## Commands

- [`ed cleaner scan`](./scan.md)
- [`ed cleaner categories`](./categories.md)
- [`ed cleaner clean`](./clean.md)
- [`ed cleaner drives`](./drives.md)

## Exit codes

| Code | When this group produces it |
| --- | --- |
| 0 | The scan, listing or clean finished. Also an empty scan, a dry run without `--yes`, a clean that trashed nothing, and `--help` or `--version` on any of these commands. |
| 1 | `--category` named one of the eight project categories and no `--root` was given, so the category cannot turn up at all. |
| 2 | The command line was wrong in ArgumentParser's own terms: an unknown flag, `--category` or `--root` with no value, or a positional argument, none of these commands take one. |
| 3 | `--category` named an id that is not one of the nineteen, or `--root` named a path that does not exist or is not a directory. |

Nothing in this group exits 4. There is no app request, no SSH and no
permission to be missing, so there is nothing that can be unavailable.

## Notes and gotchas

- Moving to the Trash is not freeing space. `moved 5.5 GB to the Trash` means
  5.5 GB is still on the disk under `~/.Trash`, so empty the Trash afterwards
  if the point of the exercise was capacity.
- `ed cleaner clean` trashes everything the scan found. The Cleaner card's
  checkboxes live in `cleanerSelectionOverrides` and `cleanerCategoryDefaults`,
  and `ed` reads neither, so the CLI is always the equivalent of ticking Select
  all. `ed config ls --group cleaner` shows those four keys, and setting them
  changes the card rather than the CLI.
- The card's drive picker is the same story. It sweeps whatever
  `cleanerSelectedDrives` and `cleanerCustomFolders` hold, defaulting to your
  home folder; `ed` sweeps nothing at all unless you pass `--root`. Two
  surfaces, one catalogue, different scopes.
- Passing `--root` also changes how a bad `--category` is treated. Without a
  root, an unknown id exits 3 and a project id exits 1. With a root, both
  errors are swallowed: the fixed-cache lookup is skipped and the swept results
  are filtered by that id, so `ed cleaner scan --root ~/code --category bogus`
  prints `nothing to reclaim` and exits 0. Check the spelling with
  `ed cleaner categories` and the list in the exit-3 hint before you rely on a
  filtered clean.
- `--category` is matched exactly and case-sensitively against the id, so
  `--category NPM` and `--category node_modules` both exit 3. The id, not the
  display name, is what the flag takes.
- Repeating the same folder repeats its results. `--root ~/code --root ~/code`
  reports every match twice and doubles the total, because the sweep walks each
  root independently and does not deduplicate paths. Cleaning that is harmless,
  the second attempt on an already trashed path simply fails and is skipped,
  but the byte count you were shown was wrong.
- The project sweep has hard limits, and there is no warning when they bite. It
  stops after 600 matched directories in total, across all roots, and it never
  looks more than ten levels below a root. A very large or very deep tree can
  therefore report less than is really there.
- The sweep never follows symlinks, never descends into a directory whose name
  begins with a dot, and never descends into anything named `System`,
  `Library`, `Applications`, `usr`, `bin`, `sbin`, `opt`, `private`, `cores`,
  `dev`, `Volumes`, `Network` or `Photos Library.photoslibrary`. Dot-named
  targets are still matched: `.venv`, `.next`, `.gradle` and `.turbo` are found
  because the name is checked against the target list before the dot rule is
  applied. What the dot rule prevents is descending into unrelated dot
  directories.
- A matched directory is never descended into, so nested junk is counted once.
  A `node_modules` inside a `node_modules` is part of the outer one's size and
  is not reported separately.
- For the fixed caches, `ed` trashes the **children** of the cache directory,
  not the directory itself, so `~/.npm/_cacache` survives as an empty folder.
  The exception is a cache directory whose visible listing is empty: then the
  directory itself becomes the single item and is trashed whole. Hidden entries
  are not listed as items, but they are counted in a parent's size and they go
  with the parent when the parent is what gets trashed.
- Zero-sized items are dropped, and a category with no items left is dropped
  entirely. That is why `ed cleaner categories` lists eleven rows and a scan
  usually prints fewer.
- Sizes in the tables use powers of 1000, so `2.3 GB` is 2,273,554,432 bytes.
  `sizeBytes`, `totalBytes`, `wouldReclaimBytes` and `reclaimedBytes` in the
  JSON are exact byte counts, and every one of them is allocated size on disk
  rather than logical file length.
- A scan is not cheap and is not cached. Every invocation walks the caches
  again, and `clean` walks them a second time before it touches anything, so
  the two-step `scan` then `clean --yes` costs two full walks. The spinner line
  is where you see which cache the seconds are going into; on a machine with a
  large Bun or npm cache it will sit on that one row for most of the run.
- The spinner line is for a person watching and nothing else. It goes to
  stderr, and it is skipped entirely when stderr is not a terminal, when
  `--json` is passed, or when `NO_COLOR` is set or `TERM` is `dumb`. A run whose
  stderr is a pipe or a file therefore produces the table and not a single
  progress byte; redirecting stdout alone does not turn it off, because it is
  stderr that is checked.
- Completion knows less than the commands do. `ed cleaner clean --<TAB>` never
  offers `--root`, and `ed cleaner clean --category <TAB>` offers nothing at
  all. The eleven fixed ids hang off `scan`'s first positional slot, and because
  the engine drops flag words before it counts positionals they surface for
  `ed cleaner scan --category <TAB>` too, which is the one place they are worth
  having. The eight project ids are never offered anywhere. All of that is the
  completion tree being a hand-maintained mirror. The flags themselves work
  exactly as documented above.
- `--help` works on the group and on all four verbs, prints on stdout and exits
  0. `ed cleaner` on its own does not print help: it runs a full scan, because
  `scan` is the default subcommand.

## Where to go next

- [`ed system`](../system/README.md), whose `disks` verb reports free space on each
  volume, which is the number `cleaner drives` deliberately does not give you.
- [`ed config`](../config/README.md), for the four `cleaner` group settings that drive
  the Cleaner card's selection and drive picker.
- [Conventions and contracts](../conventions.md), for the exit code and `--json`
  rules this page leans on.
- [All `ed` commands](../README.md).
