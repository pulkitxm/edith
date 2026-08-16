# Getting started with `ed`

`ed` is the command line for Edith, the macOS menu bar app. It ships inside the
app bundle, links itself onto your `PATH` the first time the app runs, and
reaches everything the UI reaches: settings, extensions, permissions, agent
usage, this Mac's metrics, playback, your calendar, and the machines Edith can
talk to over SSH.

`ed`, `edh` and `edith` are one command line under three names. `ed` and
`edith` are symlinks to the same binary, `edh` is a second executable built from
the same sources, and all three run the same entry point with the same
arguments, so every example on this page and everywhere else works with any of
them. Pick whichever name your shell leaves free.

This page covers the commands you meet before any of the others: getting the
links in place, reading the built-in manual, printing the config schema,
checking the version, and wiring up shell completion. None of it needs Edith to
be running.

## At a glance

| Command | What it does |
| --- | --- |
| `ed install` | Link `ed`, `edh` and `edith` into a directory on `PATH` |
| `ed uninstall` | Remove those three links again, and nothing else |
| `ed guide` | Print the built-in manual, written for agents and humans alike |
| `ed guide claude` | Print a `CLAUDE.md` snippet that makes another repo `ed`-aware |
| `ed schema` | Print the JSON Schema for the configuration document |
| `ed version` | Print the CLI version, and with `--json` whether the app is running |
| `ed completions` | The completion group; with no subcommand it runs `install` |
| `ed completions install` | Write completion scripts for the shells found on this Mac |
| `ed completions zsh` | Print the zsh completion script on stdout |
| `ed completions bash` | Print the bash completion script on stdout |
| `ed completions fish` | Print the fish completion script on stdout |
| `ed __complete` | Hidden: the candidate generator every completion script calls |

## Installing and linking

Installing Edith installs the CLI. On launch the menu bar app links `ed`, `edh`
and `edith` into `/usr/local/bin` when that directory is writable, and into
`~/.local/bin` otherwise, and it only redoes the work when the links do not
already point at the copies inside the bundle.

The directory rule is the same wherever it is applied: `/usr/local/bin` if the
current user can write to it, `~/.local/bin` if not. `ed install --directory`
overrides it and creates the directory when it is missing. `ed uninstall` does
not take the flag at all, and only ever looks in the default one.

The three links are not identical. `ed` and `edith` both point at the bundled
`ed` binary; `edh` points at the separate `edh` binary beside it. That is why a
build that produced only one of them links some names and skips others.

Building from source without the app bundle:

```
make cli
```

That builds `ed` and `edh` in release configuration, runs
`.build/release/ed install --directory $HOME/.local/bin`, and then
`.build/release/ed completions install`. It is the supported way to get a
working `ed` out of a checkout, and running `install` from the build product
rather than from a link is the part that matters, for the reason in
[`ed install`](#ed-install) below.

## Commands

- [`ed install`](./install.md)
- [`ed uninstall`](./uninstall.md)
- [`ed guide`](./guide.md)
- [`ed schema`](./schema.md)
- [`ed version`](./version.md)
- [`ed completions`](./completions.md)
- [`ed completions install`](./completions-install.md)
- [`ed completions zsh`](./completions-zsh.md)
- [`ed completions bash`](./completions-bash.md)
- [`ed completions fish`](./completions-fish.md)
- [`ed __complete`](./complete.md)

## How completion is wired

Completion is dynamic rather than a static word list. Each shell script is a
thin shim: it hands the words and the cursor position to `ed __complete` and
prints back whatever comes out, so the candidates are computed by the same
binary you are running and cannot drift out of date with it.

The path to `ed` is baked into the script when it is generated. The generator
uses the installed copy in the preferred directory when that is executable,
otherwise the copy inside the app bundle, otherwise the bare word `ed`, and the
script falls back to `ed` on `PATH` at runtime if the baked path is not
executable. That is what keeps completion working when the app moves.

What `__complete` offers, in the order it decides:

- If the first word after `ed` names a configured machine and is not a command,
  the whole thing is handed to that machine. See below.
- If the word being completed starts with `-`, the candidates are that command's
  options plus `--json` and `--help`.
- Otherwise the candidates are the subcommand names at that point, plus every
  configured machine name at the top level, plus the values for whichever
  positional slot the cursor is in.

The typed slots are what make it useful: machine names where a machine goes,
setting keys where a key goes, that setting's allowed values where its value
goes (`ed config set limitsProvider <TAB>` gives `claude codex`, and a boolean
setting gives `true false`), extension ids, permission ids, shell names, config
groups, usage ranges, app action names, cleaner category ids, colour formats and
docker prune targets in their own slots, and `#files` where a local path goes.
Matching is a case-sensitive prefix, and duplicates are dropped while the order
is kept.

Remote completion is the interesting one. `ed studio docker <TAB>` does not consult
a list of docker subcommands baked into `ed`; it asks the machine. At the first
word after the machine name `ed` runs `compgen -c` there, so you get commands
from the remote `PATH`. After `cd`, `pushd` or `rmdir` it runs `compgen -d`, so
you get directories. Anywhere else it runs a small bash harness that sources the
machine's own bash-completion, calls `_completion_loader` for the command you
are typing, finds the function registered with `complete -F`, and runs it, so
`ed studio launchctl pri<TAB>` and `ed studio brew <TAB>` complete against the tools
installed there, including ones `ed` has never heard of. Whichever of the three
runs, it is prefixed with the directory that machine's `cd` last left you in and
given six seconds; the command and directory lookups are also capped at 2000
entries. Whatever comes back is filtered by the prefix you have typed.

Remote completion only runs when a ControlMaster socket for that machine is
already open. Pressing TAB never dials a sleeping host and never blocks the
shell; with no open connection you get no candidates at all, silently and
immediately:

```
$ ed __complete --index 2 -- ed studio upt
$ echo $?
0
```

One caveat worth knowing: the tree `__complete` walks is a hand-maintained
mirror of the command surface rather than something derived from the parser. A
new flag completes only once it has been added there too, and a group command
can be offered `--json` and `--help` even where only its subcommands take them.

## The machine shorthand

Naming a machine as the first word runs the rest of the line there:

```
ed studio uptime
ed studio docker compose up -d
ed studio launchctl print system
ed studio 'ls -la /srv | head'
```

This happens before the parser sees anything. The raw arguments are rewritten
against the machine list loaded from Edith's own machines file, and the rules
are short:

- A first word starting with `-` is left alone, so `ed --help` and `ed
  --version` behave normally.
- A first word that is one of Edith's own command names is left alone. The
  reserved set is every top-level command name and alias, plus `help` and
  `__complete`, so `music`, `np`, `dl`, `colour` and the rest all win.
- A first word that equals a configured machine's display name or its ssh config
  alias, ignoring case, is a machine. It has to be the whole name: a prefix does
  not trigger the shorthand, even though a prefix does resolve once the command
  is running.
- With something other than flags after it, the line becomes
  `ed machines exec <machine> -- <rest>`. With nothing after it, or only flags,
  it becomes `ed machines show <machine>`.

`ed machines <machine> <subcommand...>` is reshuffled the same way, so the
machine can come second and read naturally. The rewriter consumes subcommand
names from the machines subtree until it hits a flag or a word that is not a
subcommand, then puts the machine after them:

| What you type | What actually runs |
| --- | --- |
| `ed studio` | `ed machines show studio` |
| `ed studio --json` | `ed machines show studio --json` |
| `ed studio uptime` | `ed machines exec studio -- uptime` |
| `ed machines studio` | `ed machines show studio` |
| `ed machines studio metrics --follow` | `ed machines metrics studio --follow` |
| `ed machines studio docker ps` | `ed machines docker ps studio` |
| `ed machines studio files ls /var/log` | `ed machines files ls studio /var/log` |

Edith's own command names win over machine names, in both positions. A machine
called `usage` still needs `ed machines exec usage -- ...`, and a machine called
`ls` or `docker` needs `ed machines show ls`, because after `ed machines` a word
that is a subcommand of `machines` is read as that subcommand. A machine name
with spaces needs quoting, and quoting is enough: `ed "Studio Mac" uptime`
works.

The reserved list comes from the same hand-maintained tree that drives
completion, not from the parser, so it is the tree that decides which names a
machine can never take.

## Exit codes

Only the codes this page's commands produce.

| Code | What produced it |
| --- | --- |
| 0 | The command did what it says, including `ed install` reporting a problem in the `message` field of `--json`, `ed uninstall` finding nothing to remove, and `--help` or `--version` on any command but `__complete`, which captures both as words and still exits 0 |
| 1 | `ed install` without `--json` when no `ed` binary can be found near the running executable, or a write that fails while `ed completions install` is creating a script |
| 2 | The command line was wrong: an unknown flag, a missing value, or a positional the command does not take, such as `ed completions install zsh` |
| 3 | `ed guide <topic>` for any topic other than `claude`, or `ed completions install --shell <anything but zsh, bash or fish>` |

Nothing on this page returns 4. None of these commands needs Edith to be
running, which is the point: they are what you run before, or instead of,
anything that does.

## Notes and gotchas

- Every command here works with Edith closed. `ed version --json` reports
  `appRunning` as a fact rather than failing on it, and the rest do not care.
- Diagnostics go to stderr as `error:` and `hint:` lines, and notes such as
  `note: <directory> is not on PATH` go there too, so stdout stays exactly one
  document you can pipe.
- Object keys in every JSON document are sorted, indentation is two spaces, and
  a field with no value is present as `null` rather than dropped. `ed install
  --json` always has a `message` key even when nothing went wrong.
- Run `ed install` from the app's own copy or from a fresh build, never through
  a link already on your `PATH`, or you will relink `ed` and `edh` onto
  themselves. `make cli` gets this right.
- `ed uninstall` looks only in the default directory. Links placed with
  `ed install --directory` survive it.
- `ed install` replaces any symlink at those names, and `ed uninstall` removes
  any symlink at those names, in both cases without asking where it points. A
  regular file with one of those names is never touched.
- The menu bar app relinks the CLI on launch when the links are wrong, and
  rewrites the completion scripts when `completionsAutoRefresh` is set and the
  script it wrote is stale. It does both on a background queue, and neither ever
  overwrites a regular file: relinking only ever replaces a symlink, and the
  refresh only rewrites a script that already contains `__complete`.
- `ed completions install` edits `~/.zshrc` and `~/.bashrc`, inside a marked
  block it can find again. Removing the block by hand is enough to undo it.
- `ed completions` with no subcommand installs. It does not print help.
- `ed schema` output is what `ed config import` accepts, so it is worth keeping
  next to any configuration you generate.

## Where to go next

- [`ed config`](../config/README.md), which is what `ed schema` describes and what
  `ed guide` points at first.
- [`ed machines`](../machines/README.md), for everything the machine shorthand is
  shorthand for.
- [All the command pages](../README.md).
