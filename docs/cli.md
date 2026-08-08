# The `ed` command line

`ed` is the command line for Edith. It ships inside the app, links itself onto
your `PATH` the first time the app runs, and reaches everything the UI reaches:
settings, extensions, permissions, agent usage, this Mac's metrics, playback,
your calendar, and the machines Edith can talk to over SSH.

`edh` and `edith` are the same binary under different names. Every example below
works with any of the three.

The built-in manual is `ed guide`, which is written for agents and humans alike
and is the shortest path to being useful. This page is the complete reference.

## Contents

- [Install](#install)
- [Conventions](#conventions)
- [Shell completion](#shell-completion)
- [`ed guide`, `ed schema`, `ed version`](#ed-guide-ed-schema-ed-version)
- [`ed config`](#ed-config)
- [`ed extensions`](#ed-extensions)
- [`ed permissions`](#ed-permissions)
- [`ed usage`](#ed-usage)
- [`ed system`](#ed-system)
- [`ed music`](#ed-music)
- [`ed calendar`](#ed-calendar)
- [`ed clipboard`](#ed-clipboard)
- [`ed tools`](#ed-tools)
- [`ed apps`](#ed-apps)
- [`ed download`](#ed-download)
- [`ed color`](#ed-color)
- [`ed shelf`](#ed-shelf)
- [`ed cleaner`](#ed-cleaner)
- [`ed machines`](#ed-machines)
- [Running a command on a machine](#running-a-command-on-a-machine)
- [What needs the app running](#what-needs-the-app-running)

## Install

Installing Edith installs the CLI. On launch the app links `ed`, `edh` and
`edith` into `/usr/local/bin` when that directory is writable, and into
`~/.local/bin` otherwise. It only ever replaces links it owns; a real file of
the same name is left alone and reported as skipped.

To place the links yourself:

```
ed install                       link into the default directory
ed install --directory ~/bin     link somewhere specific
ed install --json                the directory, what was linked, and whether it is on PATH
ed uninstall                     remove the links, leave everything else
```

Building from source without the app bundle:

```
make cli                         builds ed and edh, links them, installs completions
```

## Conventions

These hold for every command, and they are the contract an agent should rely on.

- **`--json` on every read command.** stdout is exactly one JSON document.
  Object keys are sorted, so output diffs cleanly.
- **stdout is data, stderr is commentary.** Errors, hints and notes go to
  stderr. On failure stdout may be empty.
- **Exit codes are the contract.**

  | Code | Meaning |
  | --- | --- |
  | 0 | success |
  | 1 | the command failed |
  | 2 | the command line was wrong: an unknown flag, a missing argument, or a value outside what the option accepts |
  | 3 | the thing you named does not exist (machine, setting, extension) |
  | 4 | unavailable: the app is not running, a machine is down, a permission is missing |

  `ed machines exec` is the exception in a useful way: it propagates the remote
  command's own exit code.
- **Discover, then act.** `ed machines ls`, `ed config ls`, `ed extensions ls`
  and `ed usage sources` are cheap and tell you the exact names every other
  command expects.
- **Names are forgiving.** Machines resolve by display name, SSH alias, id, or
  any unambiguous prefix, case-insensitively. An ambiguous prefix fails with the
  list of matches rather than guessing.

## Shell completion

```
ed completions install              write scripts for every shell found
ed completions install --shell zsh  just one
ed completions zsh                  print the script, place it yourself
ed completions bash
ed completions fish
```

`install` writes to `~/.local/share/zsh/site-functions/_ed`,
`~/.local/share/bash-completion/completions/ed` and
`~/.config/fish/completions/ed.fish`, and prints the one line you may need to
add to your shell's rc file. `make cli` runs it for you.

Completion is dynamic, not a static word list. It offers:

- command names at the top level, plus every configured machine
- setting keys where a key goes, and that setting's allowed values where a value
  goes (`ed config set limitsProvider <TAB>` gives `claude codex`)
- extension ids, permission ids, usage ranges, config groups and shell names in
  their own slots
- file paths where a local path goes
- **after a machine name, whatever that machine would have completed**

That last one is the interesting one. `ed tuf docker <TAB>` does not consult a
list of docker subcommands baked into `ed`; it asks the machine. `ed` runs the
remote shell's own programmable completion for the command you are typing and
returns what it produced, so `ed tuf docker compose <TAB>`, `ed tuf systemctl
sta<TAB>` and `ed tuf apt <TAB>` all complete against the tools installed there,
including ones `ed` has never heard of. At the first word after the machine name
it completes command names from the remote `PATH` instead.

Remote completion only runs when a ControlMaster socket for that machine is
already open. Pressing TAB never dials a sleeping host and never blocks the
shell; with no open connection you simply get no remote candidates.

## `ed guide`, `ed schema`, `ed version`

```
ed guide            the built-in manual
ed guide claude     a CLAUDE.md snippet that makes another repo ed-aware
ed schema           JSON Schema for the configuration document
ed version [--json] the CLI version, and whether the app is running
ed app relaunch     quit Edith and start it again, which a new grant needs
ed app clear-updates  forget the record of past update checks
```

`ed guide claude` prints a section you can paste into any repository's
`CLAUDE.md` so an agent working there knows `ed` exists and how to use it.

## `ed config`

Every preference the UI writes is a key in the same defaults suite the app
reads. A change made here reaches the running app immediately: `ed` posts the
same `settingsChanged` notification the app posts to itself.

```
ed config ls [prefix] [--group <g>] [--changed] [--json]
ed config get <key> [--json]
ed config set <key> <value> [--json]
ed config unset <key> [--json]
ed config describe <key> [--json]
ed config export [--defaults] > edith.json
ed config import <file|-> [--dry-run] [--json]
```

`ls` prints key, group, type and current value. `--group` narrows to one of:
`appearance panel usage limits menubar alerts budget dashboard machines finder
system cleaner music calendar clipboard notch focusdim presenter colorpicker
micmute backup permissions`. `--changed` shows only settings with a stored
value.

`describe` is what to read before writing something you are unsure of:

```
$ ed config describe limitsProvider
limitsProvider
  Provider shown first in the limits UI.
  type     string
  group    limits
  scope    shared
  allowed  claude, codex
  default  claude
  value    claude
```

`set` validates before it writes. An unknown key exits 3 with near matches; a
value of the wrong type or outside the allowed set exits 1 and nothing is
written. Booleans accept `true/false`, `yes/no`, `on/off`, `1/0`,
`enabled/disabled`. List settings take a comma-separated value.

A handful of keys are read only, because the app owns them: the
`perm*Granted` mirror of macOS permission state and the `last*BackupAt`
timestamps. Writing one exits 1.

`export` emits only the settings you have actually changed, which is exactly
what `import` accepts, so moving your setup to another Mac is a two-command
operation. `--defaults` includes everything at its current effective value.
`--dry-run` reports what would change without writing. A setting whose value
already matches is counted as unchanged rather than applied, so re-importing a
document you just exported reports that nothing would change:

```
$ ed config export > edith.json
$ ed config import edith.json --dry-run
would apply 0 settings
83 already matched
```

Useful ones:

```
ed config set preventSleep true          Keep Awake on
ed config set presenterMode true         Presenter mode on right now
ed config set presenterAutoEnabled true  and turn it on automatically when sharing
ed config set warnPercent 70             amber threshold for rate limits
ed config set limitsInMenuBar false      hide the menu bar percentages
ed config set appearance dark
```

## `ed extensions`

Extensions are settings, but they get their own verbs because turning one on can
need a macOS permission.

```
ed extensions ls [--json]
ed extensions enable <id> [--json]
ed extensions disable <id> [--json]
ed extensions info <id> [--json]
```

Ids are `usage system machines systemStats micMute music calendar notchShelf
clipboard focusDim presenter colorPicker`. Enabling one whose required
permission is missing still enables it and prints, on stderr, which permission
to request. `info --json` includes `missingRequiredPermissions` so an agent can
check without parsing prose.

## `ed permissions`

A command line process cannot read another application's TCC state, and it must
not try: the grants belong to the Edith bundle, not to `ed`. So `ed` reports
what the app itself last observed and mirrored into its preferences, and asks
the app to do anything that needs a real prompt.

```
ed permissions ls [--attention] [--json]
ed permissions refresh [--json]
ed permissions request <permission> [--json]
```

`refresh` asks the running app to re-read the real state and then reports it;
run it if you suspect the mirror is stale. `request` asks the app to raise the
system prompt, waits, and reports whether the grant landed. Both need the app
running and exit 4 otherwise.

`ls --json` includes `appRunning` so you can tell a stale mirror from a live
one. Bluetooth and Automation are granted by macOS on first use and cannot be
requested ahead of time; asking exits 4 and says so.

## `ed usage`

Numbers come from the same `usage.json` the dashboard reads and the same
`limits-history.jsonl` the rings read. `ed` does not re-derive anything, so the
CLI and the UI cannot disagree.

```
ed usage limits [--refresh] [--json]
ed usage summary [--range <r>] [--source <s>]... [--machine <m>]... [--json]
ed usage daily   [--range <r>] [--source <s>]... [--machine <m>]... [--json]
ed usage models  [--range <r>] [--source <s>]... [--machine <m>]... [--json]
ed usage projects [--range <r>] [--limit <n>] [--json]
ed usage sources [--json]
ed usage machines [ls] [--json]
ed usage machines collect [<machine>] [--once] [--verbose] [--timeout <s>] [--json]
ed usage machines enable <machine> [--json]
ed usage machines disable <machine> [--json]
ed usage machines forget <machine> [--json]
ed usage refresh [--follow] [--json]
```

`ed usage refresh` runs the collection pipeline itself, so it does not need the
Edith app to be open. It prints each phase as it completes. When a refresh is
already running, in the app or in another terminal, it attaches to that one and
reports its progress rather than starting a second; `--follow` requires a
running refresh and never starts one. Progress goes to stderr and is skipped
when stderr is not a terminal, so `ed usage refresh --json` stays pipeable.

`--range` is `today`, `week` (last 7 days), `month` (last 30) or `all`, and
defaults to `all`. `--source` filters to one agent and repeats;
`ed usage sources` lists the valid values.

`--machine` filters to everything one machine ran, by the machine's name
rather than by source id, and repeats. `--machine local` is this Mac on its
own. Naming a machine that has never given usage is an error rather than a
silent empty answer, and `ed usage sources` has a MACHINE column so you can
see which is which.

```
$ ed usage summary --machine "Asus TUF 7"
cost    $254.07
tokens  329833432
days    81

SOURCE          COST    TOKENS
asus-tuf-7:cli  254.07  329833432
```

```
$ ed usage limits
PROVIDER  SESSION  WEEKLY  SESSION RESETS  OBSERVED
Codex     -        100.0%  -               2026-08-06T22:57:22Z
Claude    46.0%    34.0%   3h 27m          2026-08-06T23:02:21Z
```

`limits --refresh` asks the running app to poll the providers again and waits
for the answer before reporting, which is the refresh button on the rate limit
cards. It needs the app running; without `--refresh` the command reads the
collected file and does not.

`limits --json` gives each provider a `session` and `weekly` object with
`percent`, `resetsAt` and `resetsInSeconds`, or `null` where the provider has
never reported that window.

`machines` counts SSH machines alongside this Mac. `collect` pipes the same
collector Edith runs here to the machine, runs it against that machine's home
and brings the numbers back, so a box you only ever reach over SSH shows up in
every other `ed usage` answer. What the machine is missing (jq, bun, ccusage) is
installed under `~/.cache/edith` there on the first run, which is why nothing is
collected until you ask: naming a machine to `collect` signs it up for later
refreshes, `--once` collects without signing it up, and `disable` stops the
refreshes while keeping the numbers.

Each agent on a machine arrives as its own source, `<machine-slug>:<agent>`,
labelled with the machine name, so `--source asus-tuf-7:cli` narrows to one
agent on one machine and `ed usage sources` lists them next to the local ones.
`forget` drops everything one machine gave and stops counting it.

```
$ ed usage machines
MACHINE     COUNTED  COLLECTED             SOURCES  COST    TOKENS
Asus TUF 7  yes      2026-08-08T16:14:51Z  1        249.81  321812580
```

`refresh` asks the running app to re-collect, and waits for it to finish so you
can gate on the exit code; `--no-wait` returns as soon as the request is sent.
It needs the app running. Everything else reads files and works whether the app
is running or not, though it exits 4 if the Agent Usage extension has never
collected anything.

## `ed system`

```
ed system stats [--follow] [--interval <s>] [--processes <n>] [--json]
ed system disks [--json]
```

`stats` samples CPU, memory, load, uptime and network for this Mac using the
same sampler the app's local machine view uses. `--follow` keeps sampling until
interrupted; with `--json` each sample is one compact JSON document per line, so
it pipes into `jq` cleanly. `--processes n` includes the top n processes by CPU.

## `ed music`

```
ed music status [--json]
ed music play | pause | toggle | next | previous
ed music volume <0..1>
ed music start <track> | --folder <folder>
ed music seek <0..1>
ed music shuffle [on|off]
ed music repeat  [on|off]
ed music rescan
```

`start` plays something specific out of Edith's own library, so it needs the app
running; `play` resumes whatever player is already going, including Spotify and
Apple Music. `shuffle` and `repeat` report the current state when given no
argument.

### The library

Edith's own library is a folder of files, so these work on disk and do not need
the app running. `ed config set musicFolderPath <dir>` chooses the folder;
`ed config set musicShuffling`/`musicLooping` are the footer toggles.

```
ed music ls [folder] [--folders] [--recursive] [--search <text>] [--json]
ed music mkdir <name> [--under <folder>] [--json]
ed music mv <track> <folder> [--json]
ed music rename [--folder] <target> <name> [--json]
ed music rm [--folder] <target> [--yes] [--json]
```

Paths are relative to the library root. A track can be named by its path or by
enough of its title to be unambiguous; a prefix matching more than one exits 3
and lists what it matched, rather than guessing:

```
$ ed music mv e Chill
error: e matches 2 tracks
hint: beta-tune.mp3, Focus/delta-loop.mp3
```

`rename` keeps the extension, so `ed music rename alpha-song.mp3 "Night Drive"`
gives `Night Drive.mp3`. `--folder` renames a folder instead. Moving onto a name
that already exists is refused rather than overwriting.

`rm` moves to the Trash rather than deleting, the same as the UI, and does
nothing without `--yes`. Favourites follow a track that is renamed or moved, and
a rename reaches the running player so playback does not break.

Playback lives in the menu bar app, so these talk to it over the app's own
notification bus. `status --json` reports the track's relative path, title,
play state, elapsed and total seconds, volume, and the loop and shuffle flags.
They exit 4 when the app is not running or the Music extension is off.

## `ed calendar`

```
ed calendar ls [--days <n>] [--json]
```

Events come from the running app, because the calendar grant belongs to the
Edith bundle. `--days` limits to events starting within that window, default 7.
Output carries title, calendar name, start, end, all-day flag, location and a
detected meeting link.

This exits 4 with a specific reason when it cannot answer: the app is not
running, the Calendar extension is off, or macOS has not granted Edith calendar
access.

## `ed clipboard`

The history is a file on disk, so the read commands work whether or not the app
is running. Entries are numbered from 1 in the same order the panel shows them:
pinned first, then most recently copied, honouring `clipboardPinTo`. That number
is what every other verb takes, and it is the same entry the UI would act on.

```
ed clipboard ls [--pinned] [--search <text>] [--limit <n>] [--json]
ed clipboard stats [--json]
ed clipboard get <n> [--json]
ed clipboard copy <n> [--plain] [--json]
ed clipboard pin <n> [--json]
ed clipboard unpin <n> [--json]
ed clipboard rm <n> [--json]
ed clipboard clear [--keep-pinned] [--json]
```

`ls` shows 25 entries; `--limit 0` shows all of them, and a truncated list says
so on stderr. `--search` matches the preview text and the source application,
case-insensitively, which is the same match the panel's search field makes.

`stats` is how to see how much the history is holding:

```
$ ed clipboard stats
ITEMS  PINNED  SIZE   ON DISK  LARGEST  OLDEST
1217   3       46 MB  46.7 MB  9.2 MB   2026-07-27T09:43:29Z

KIND      COUNT  SIZE
text      517    337 KB
richText  40     28 KB
html      229    2.4 MB
image     35     43.2 MB
file      87     72 KB
data      309    39 KB
```

`sizeBytes` totals what the entries claim; `diskBytes` is what the blob
directory actually occupies. They differ when a blob is shared or orphaned.

`copy` puts an entry back on the pasteboard and, like clicking it in the panel,
bumps it to the top of the history. `--plain` strips styling from a rich entry.
`pin` keeps an entry out of the retention sweep that `clipboardMaxItems` and
`clipboardMaxAgeDays` drive; pinning something already pinned reports that on
stderr and still exits 0.

## `ed tools`

The command line tools an extension needs before it can work: yt-dlp for
downloads, and the agent CLIs whose limits the dashboard reads.

```
ed tools ls [--json]
ed tools install <yt-dlp|claude|codex> [--json]
```

```
$ ed tools ls
ID      STATE      VERSION                     WHY
yt-dlp  installed  2026.07.04                  Downloads YouTube audio into your Music library.
claude  installed  2.1.226 (Claude Code)       Includes Claude Code cloud sessions in Agent Usage.
codex   installed  codex-cli 0.146.0-alpha.9.2 Reads Codex session and weekly limits when that provider is enabled.
```

`ls` checks PATH and needs nothing. `install` fetches the tool itself, the same
way the extension sheet does, and needs no app running. It streams what it is
doing, verifies the tool is on PATH afterwards, and exits 4 with the manual
instruction when it could not. A tool that is already there is reported rather
than reinstalled.

## `ed apps`

```
ed apps ls [--json]
ed apps quit <app> [--force] [--json]
ed apps quit --all [--force] --yes [--json]
```

`ls` reads the process table and needs nothing. Quitting asks the Edith app to
send the quit event, because that belongs to the app's Automation grant rather
than to `ed`, so it exits 4 when Edith is closed. An app resolves by name, by
bundle id, or by an unambiguous prefix.

Finder, Edith and its menu bar helper are never quit, whichever surface asks.
`--all` does nothing without `--yes` and reports the count first:

```
$ ed apps quit --all
would quit 7 app(s)
nothing was quit; pass --yes to go ahead
```

`--force` uses `forceTerminate`, which does not let an app save first.

## `ed download`

The queue Edith feeds to yt-dlp. It is a file, so listing, adding and clearing
work whether or not the app is running. Edith is what actually runs yt-dlp, so
anything added while it is closed waits and starts when you open it, and `ed`
says so on stderr.

```
ed download ls [--active] [--limit <n>] [--json]
ed download add <url>... [--kind audio|video] [--prefix <text>] [--json]
ed download retry <n> | --all [--json]
ed download rm <n> [--json]
ed download clear [--everything] [--json]
ed download cancel [--json]
ed download tool [--update] [--json]
```

`add` accepts several links at once and ignores anything in the argument that is
not a URL, the same parser the sheet's paste box uses. `clear` forgets what has
finished; `--everything` also drops what is queued or running. `tool` reports
which yt-dlp is being used and its version, and `--update` runs its self-update:

```
$ ed download tool
2026.07.04  /Users/pulkit/Library/Application Support/Edith/bin/yt-dlp
```

## `ed color`

```
ed color ls [--format <f>] [--limit <n>] [--json]
ed color clear [--json]
```

`--format` prints one representation per line and nothing else, so
`ed color ls --format hex --limit 1` is the last colour you picked. Formats are
`hex`, `rgb`, `hsl`, `swiftUI` and `nsColor`. `colour` is an accepted spelling.

## `ed shelf`

```
ed shelf ls [--json]
ed shelf path <n> [--json]
ed shelf add <file> [--json]
ed shelf rm <n> [--json]
ed shelf clear [--json]
```

`add` copies the file onto the shelf rather than moving it, and renames it if
the shelf already holds that name. `path` prints the copy's location, which is
what to pipe into another tool.

## `ed cleaner`

```
ed cleaner categories [--json]
ed cleaner drives [--json]
ed cleaner scan  [--category <c>] [--root <dir>]... [--json]
ed cleaner clean [--category <c>] [--root <dir>]... [--yes] [--json]
```

Without `--root` these measure the fixed caches `ed cleaner categories` lists.
`--root` also sweeps a folder for project junk, which is what the drive picker
does, and is the only way the sweep-only categories exist at all:
`nodeModules`, `pycache`, `pyvenv`, `rustTarget`, `gradle`, `pods`, `nextBuild`
and `turbo`. Naming one without a root says so rather than pretending it is
unknown:

```
$ ed cleaner scan --category nodeModules
error: nodeModules only turns up when a folder is swept for project junk
hint: pass --root, for example `ed cleaner scan --root ~/code --category nodeModules`

$ ed cleaner scan --root ~/code --category nodeModules
ID           SIZE     ITEMS  NAME
nodeModules  86.6 MB  1      node_modules
```

`clean` without `--yes` reports what it would move and touches nothing. With
`--yes` it moves the files to the Trash; it never deletes, so a mistake is
recoverable from Finder.

## `ed machines`

Machines come from Edith's own machine list, so `ed` never asks you to re-enter
a host. Transport is `/usr/bin/ssh` over a ControlMaster socket shared with the
app: if the app already holds a connection, `ed` reuses it and each command is
one round trip on an open channel. If it does not, `ed` opens one, and that
socket outlives the process so the next command is fast.
`ed machines disconnect` closes it.

```
ed machines ls [--json]
ed machines show <machine> [--json]
ed machines metrics <machine> [--follow] [--interval <s>] [--processes <n>] [--json]
ed machines exec <machine> [--] <command...>
ed machines services <machine> [--failed] [--json]
ed machines broadcast [--only <a,b>] [--] <command...> [--json]
ed machines connect <machine> [--json]
ed machines disconnect <machine> [--json]
```

### Keeping the list

Adding, renaming and removing machines works from here as well as from the app,
and a change reaches a running Edith immediately.

```
ed machines add <name> --host <h> [--port <n>] [--user <u>] [--key <path>]
                                 [--alias <sshAlias>] [--mac <address>]
ed machines edit <machine> [--name <n>] [--host <h>] [--port <n>] [--user <u>]
                           [--key <path>] [--agent] [--mac <address>]
ed machines rm <machine> [--yes] [--json]
```

Passwords and key passphrases are read from stdin, never taken as an argument,
so they cannot end up in a process listing or your shell history:

```
printf '%s' "$PASS" | ed machines add box --host 10.0.0.4 --user pi --password-stdin
printf '%s' "$PHRASE" | ed machines edit box --key ~/.ssh/id_ed25519 --key-passphrase-stdin
```

They go into the same login keychain item under the same service name the app
uses, so either surface can read what the other wrote, and `ed machines rm`
takes them with it.

`add` uses the SSH agent unless `--key` names a private key. `--alias` records
the machine as an entry from your `ssh config`, which is what the app's picker
writes when you choose a host from there. Password authentication is not offered
here as an argument, for the reason above.

`rm` without `--yes` reports what it would take with it and touches nothing.
With `--yes` it removes the machine, its saved forwards, its snippets and its
keychain entries. Duplicate names are refused rather than silently allowed,
because every other command resolves machines by name.

### Forwards and snippets

```
ed machines forwards ls  <machine> [--json]
ed machines forwards add <machine> --local <n> --remote <n>
                                   [--remote-host <h>] [--title <t>] [--json]
ed machines forwards on  <machine> <n> [--json]
ed machines forwards off <machine> <n> [--json]
ed machines forwards rm  <machine> <n> [--json]

ed machines snippets ls  <machine> [--json]
ed machines snippets add [--shared] [--json] <machine> <title> <command...>
ed machines snippets rm  <machine> <n> [--json]
```

These are the same lists the machine's Tools tab shows. Forwards are numbered by
local port, snippets in the order they were saved, and both are numbered from 1.
`on` and `off` open and close the tunnel on the shared connection, which is the
switch on each row of the Tools tab; `add` only saves it. Two forwards cannot
claim the same local port. `--shared` saves a snippet
against every machine rather than just this one, which is what leaving the
machine unset does in the UI.

`metrics` streams the same collector the app's Machines view uses, over stdin,
so nothing is installed on the machine. Without `--follow` it prints one sample
and exits; with it, a sample every `--interval` seconds. `--json` gives cpu
(total, steal, per core), memory (including swap and buff/cache), load, tasks,
uptime, per-device disk throughput, per-interface network throughput, and
optionally the top processes.

### Workspaces

A workspace is a saved arrangement of panes, each pointed at a machine and a
screen. These read and write the same file the Workspace view does.

```
ed machines workspace ls [--json]
ed machines workspace use <workspace> [--json]
ed machines workspace new <machine>... [--screen <s>] [--name <n>] [--json]
ed machines workspace rename <workspace> <name> [--json]
ed machines workspace rm <workspace> [--json]

ed machines workspace panes [--workspace <w>] [--json]
ed machines workspace split <pane> <machine> [--side <s>] [--screen <s>] [--json]
ed machines workspace close <pane> [--json]
ed machines workspace point <pane> [<machine>] [--screen <s>] [--json]
ed machines workspace equalize [--json]
```

Panes are numbered from 1 in the order they are laid out; `panes` prints them
with what each one shows and which is focused. `split` puts the new pane on
`--side` left, right, top or bottom. `point` retargets a pane without splitting
it. Every one of these defaults to the current workspace unless `--workspace`
names another. Closing the last pane is refused, because a workspace needs one.

`new` is the Layout menu's presets as a command: one machine gives a single
pane, several give them tiled side by side. `--screen` is `overview`,
`processes`, `docker`, `files` or `terminal`. Splitting a pane by hand and
dragging dividers stay in the view; what `ed` reaches is which layouts exist,
which one is current, and what each pane points at.

`broadcast` is the terminal's broadcast bar as a command: it runs one line on
every configured machine, labels each machine's output, keeps going when one is
unreachable, and exits 1 if any of them failed. `--only` narrows it to a
comma-separated list.

`services` parses `systemctl list-units`; `--failed` narrows to failed units.
On a machine without systemd it reports nothing rather than failing.

### Power, units and processes

```
ed machines power status   <machine> [--json]
ed machines power reboot   <machine> [--yes] [--json]
ed machines power shutdown <machine> [--yes] [--json]
ed machines power wake     <machine> [--json]

ed machines services start | stop | restart <machine> <unit> [--json]
ed machines kill <machine> <pid> [--signal <name>] [--json]
```

`reboot` and `shutdown` do nothing without `--yes`. Both go through systemd and
need privilege on the far side: `ed` tries `sudo -n` first and falls back to
plain `systemctl`. A machine that answers *a password is required* or
*Interactive authentication required* is reported as having refused, and exits
1, rather than being called done:

```
$ ed machines power reboot tuf --yes
error: Asus TUF 7 did not reboot: sudo: a password is required
Call to Reboot failed: Interactive authentication required.
hint: give this account passwordless sudo for systemctl on Asus TUF 7
```

A reboot that works takes the connection down with it; that is treated as
success rather than as an error.

`wake` sends a wake-on-LAN packet to the stored MAC address, so it is the one
that works while the machine is off. Edith learns the address the first time it
sees the machine up; `ed machines edit <machine> --mac <address>` sets it by
hand. `power status` says which of these are possible right now.

`kill` sends SIGTERM unless `--signal` names another of TERM, KILL, HUP, INT,
QUIT, USR1 or USR2, with or without the `SIG` prefix. A name that is not one of
those exits 3 rather than being passed to the remote shell.
`ed machines metrics <machine> --processes 20` lists the pids.

### Files

```
ed machines files ls  <machine> [path] [--all] [--json]
ed machines files get <machine> <remote> [local] [--json]
ed machines files put <machine> <local> <remote> [--json]
```

`ls` defaults to the remote home directory and hides dotfiles unless `--all`.
`get` defaults the local name to the remote file's name. Transfers stream over
the shared connection.

`put` takes a destination directory as well as a file path: a path ending in `/`,
or one that is a directory on the far side, keeps the local filename. An upload
is checked rather than assumed, so a transfer that is cut short reports what the
machine said and removes the partial file instead of leaving something that looks
complete:

```
$ ed machines files put tuf ./clip.mov /home/pulkit/uploads/
/home/pulkit/uploads/clip.mov  38.1 MB

$ ed machines files put tuf ./clip.mov /tmp/no-such-dir/clip.mov
error: upload failed: bash: line 1: /tmp/no-such-dir/clip.mov: No such file or directory
```

The Finder window's own operations are here too, running the same commands it
runs:

```
ed machines files cp     <machine> <path>... <directory> [--json]
ed machines files mv     <machine> <path>... <directory> [--json]
ed machines files rename <machine> <path> <name> [--json]
ed machines files mkdir  <machine> <path> [--json]
ed machines files rm     <machine> <path>... [--delete] [--yes] [--json]
ed machines files search <machine> <directory> <text> [--limit <n>] [--json]
ed machines files info   <machine> <path> [--json]
ed machines files duplicate <machine> <path> [--json]
ed machines files undo   <machine> [--json]
```

`cp` and `mv` take the destination directory last, like the shell tools they
mirror. `rename` takes a bare name, not a path, and keeps the file where it is;
renaming onto a name that already exists is refused rather than overwriting.

`rm` moves to the machine's own trash so it can be put back. `--delete` removes
for good and does nothing without `--yes`.

`undo` reverses the last move or rename a Finder window made. That history
belongs to an open window and lives in memory rather than on disk, so `ed` asks
the window to do it and tells you to open one when there is none:

```
$ ed machines files undo tuf
error: the undo history lives in an open Finder window, and Edith is not running
hint: open Edith and its Files window for Asus TUF 7, then retry
```

A move or rename made by `ed` is not on that history; reverse it with
`ed machines files mv` or `rename`, which runs what the window would have run.

`search` is the window's search field: a name match under a directory, capped at
300 hits unless `--limit` says otherwise. `info` measures a path with `du`, so
it answers for directories where `ls` only reports the entry. `duplicate` names
the copy the way the window does, `report copy.txt` then `report copy 2.txt`.

### Docker

```
ed machines docker ps      <machine> [--all] [--json]
ed machines docker images  <machine> [--json]
ed machines docker volumes <machine> [--json]
ed machines docker networks <machine> [--json]
ed machines docker df      <machine> [--json]
ed machines docker logs    <machine> <container> [--tail <n>] [--follow]
ed machines docker inspect <machine> <container>
ed machines docker start | stop | restart | pause | unpause | rm <machine> <container> [--json]
ed machines docker rmi       <machine> <image> [--force] [--json]
ed machines docker volume-rm <machine> <volume> [--yes] [--json]
```

`volume-rm` is where containers keep the data meant to outlive them, so it does
nothing without `--yes`.

`ps` merges `docker ps` with `docker stats`, so a container row carries live CPU
and memory alongside its state and ports. `--all` includes stopped containers.

```
$ ed machines docker ps tuf
ID            NAME                          IMAGE                               STATE    CPU    PORTS
b556d7fef23e  lobe-chat                     lobehub/lobe-chat:latest            running  0.0%
f8968a8b81e5  open-webui                    ghcr.io/open-webui/open-webui:main  running  0.3%   3000 → 8080/tcp
47e37ace9821  noveum-local-db-postgres-1    postgres:17-alpine                  running  2.7%   5433 → 5432/tcp
```

If docker is missing, the daemon is down, or the user cannot reach the socket,
these exit 4 and say which.

Anything not covered here goes through the raw form below; `ed tuf docker
compose up -d` is a normal thing to type.

## Running a command on a machine

```
ed <machine> <command...>
ed machines exec [--tty] <machine> [--] <command...>
```

`--tty` runs the command on a terminal, which is what anything interactive
needs: `vim`, `top`, a `sudo` password prompt, or `docker exec -it`. Without it
the command runs with no pty, which is right for scripting and wrong for a
shell.

Naming a machine as the first word runs the rest of the line there. It is
shorthand for `ed machines exec <machine> -- <command...>`, and it is the
general escape hatch: stdin is forwarded, stdout and stderr stay separate, and
the remote exit code becomes yours.

```
ed tuf uptime
ed tuf docker compose up -d
ed tuf systemctl status nginx
ed tuf tail -f /var/log/syslog
ed tuf 'ls -la /srv | head'
```

Arguments are quoted individually before they are sent, so an argument
containing spaces survives. Shell metacharacters do not: to use a pipe,
redirection or a glob on the machine, quote the whole line as in the last
example.

A bare `ed <machine>` with nothing after it is `ed machines show <machine>`.

### Staying in a directory

`cd` is remembered, so the commands after it run where you left off:

```
ed tuf pwd                      /home/pulkit
ed tuf cd Desktop
ed tuf pwd                      /home/pulkit/Desktop
ed tuf ls                       lists Desktop
ed tuf cd -                     back to where you were before
ed tuf cd                       back to the home directory
```

The directory belongs to the terminal it was set in, the same way `cd` does in
a local shell, so two tabs on one machine never move each other. Remote path
completion follows it too: `ed tuf ls <TAB>` offers what is in the directory
you are in, not what is in your home directory.

A path that does not exist reports the machine's own error and leaves the
current directory alone. One that disappears later falls back to the home
directory rather than breaking every command after it.

`cd` is only read when it is the whole command. Quoting a line keeps the old
one-shot behaviour, so `ed tuf 'cd /tmp && pwd'` prints `/tmp` and changes
nothing for the next command.

Edith's own command names win over machine names, so a machine called `usage`
still needs `ed machines exec usage -- ...`.

## What needs the app running

| Command | Needs the app? |
| --- | --- |
| `config`, `extensions`, `schema`, `guide`, `version`, `install` | no, but changes reach the app live when it is running |
| `usage limits`, `summary`, `daily`, `models`, `projects`, `sources` | no, they read the collected files |
| `usage machines ls`, `enable`, `disable` | no |
| `usage machines collect`, `forget` | no, but the numbers only reach the dashboard once the app folds them in |
| `usage refresh` | no, it runs the collection pipeline itself |
| `system stats`, `system disks` | no |
| `machines` and `ed <machine> ...` | no |
| `music`, `calendar` | yes |
| `permissions ls` | no, but it reports what the app last observed |
| `permissions refresh`, `permissions request` | yes |

Commands that need the app exit 4 and say so, which is a signal to start Edith
rather than to retry.
