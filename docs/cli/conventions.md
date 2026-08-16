# Conventions

These hold for every `ed` command, and they are the contract to rely on when
something other than a person is reading the output. None of it is written per
command. It comes from four pieces of shared machinery that every command
passes through, `execute`, `CLIFailure`, `CLIOut` and `JSONSerializer`, so a
command added tomorrow already obeys it, and a command page that repeats a rule
from this page is repeating it for convenience rather than adding one.

This page is the whole contract: what `--json` promises, which stream carries
what, what each exit code means and how each one is produced, how a failure is
printed, how flags and values are parsed, and which commands need the Edith app
to be running.

## `--json` is one document on stdout

The flag is `--json`, long form only. It is declared on each leaf command rather
than inherited from the group above it, so it belongs with the subcommand that
produces the output: `ed clipboard ls --json`. There is no `-j`.

Almost every command that offers it ends in exactly one call to `CLIOut.json`,
which serialises the value and writes it to stdout with a trailing newline. So
one invocation produces one document, and a test walks every command in the tree:
if its option list contains `--json` it must have a case in the JSON contract,
and that case's stdout must either parse as JSON or be empty.

Object keys are always emitted in sorted order, in both the pretty and the
compact form, because the serialiser sorts them before writing. Arrays keep the
order the command built them in. That is what makes two runs of the same command
diff cleanly:

```
$ ed version --json
{
  "appRunning": true,
  "version": "1.0.0"
}
```

The rest of the shape rules, all of them from the hand-written serialiser rather
than from Foundation, which is never used on the output path:

- In the pretty form, indentation is two spaces per level and `": "` follows
  each key; the compact form has neither the indent nor the space, so a key is
  followed by a bare `":"`. An empty array is `[]` and an empty object is `{}`,
  inline, with no newline inside.
- An optional value is emitted as `null` rather than having its key dropped, so
  a `--json` shape has the same keys on every run whether or not the value is
  there.
- Dates are ISO 8601 internet date time, as in `2026-08-06T22:57:22Z`. A missing
  date is `null`.
- A whole number that happens to be stored as a double prints as an integer, so
  a percentage of exactly three prints `3` and not `3.0`. A double that is not
  finite, NaN or an infinity, prints `null` rather than breaking the document.
- Strings escape only `"`, `\`, newline, carriage return, tab, and control
  characters below `0x20`. A `/` is left alone and non-ASCII text passes through
  as raw UTF-8 rather than as `\u` escapes, so a track title keeps its accents.

The top level is not always an object. Anything that is a list is a list:
`ed usage limits`, `ed usage projects`, `ed usage sources`, `ed permissions
refresh`, `ed calendar ls`, `ed clipboard ls`, `ed download ls`, `ed machines
ls`, `ed extensions ls` and `ed app actions` all emit a top-level array. Others,
`ed version`, `ed permissions ls`, `ed usage summary` and `ed install` among
them, emit an object.

Not every command takes `--json`, and the ones that do not fall into two groups.
`ed schema` and `ed config export` are already JSON and always have been, so
there is nothing to switch on. `ed guide`, `ed completions zsh`, `ed completions
bash`, `ed completions fish`, `ed machines exec`, `ed machines docker logs`,
`ed machines docker inspect` and `ed machines docker compose logs` emit
something that is not Edith's to shape: a manual, a shell script, or another
program's own output.

Two commands break the one-document rule on purpose, and only with `--follow`:

```
ed system stats --json                     one pretty document, then exit
ed system stats --json --follow            one compact document per line, until interrupted
ed machines metrics <machine> --json       one pretty document, then exit
ed machines metrics <machine> --json --follow   one compact document per line
```

Following flips the serialiser to its compact form, which is newline-delimited
JSON, so `ed system stats --json --follow | jq .` reads a sample at a time
instead of waiting for a document that never ends. The third `--follow`, on
`ed usage refresh`, means something else: it attaches to a refresh already in
flight, and still ends in one document.

One more place emits compact JSON without being asked: `ed config get` on a
setting that is not a string prints the value on one line in its human output,
so a list setting reads as `["a","b"]` rather than as one line per element.

## stdout is data, stderr is commentary

Every write goes through `CLIOut` or `CLIProgress`, and which function you call
decides the stream. `out` and `raw` write to stdout. `note`, `rawError` and
`report` write to stderr, and so does every line `CLIProgress` paints. Nothing
else writes anywhere.

So stdout carries the answer and nothing else: the table, the JSON document, the
file contents, the remote command's own output. stderr carries everything about
the answer: errors, hints, the note that a list was truncated, the note that
Edith is closed so a queued download waits, and the `waiting for Edith to
answer...` line that appears when a request to the app takes more than a second.
A test asserts that stdout never contains the substrings `error:` or `hint:`.

Progress is the rest of what stderr carries. A command that would otherwise sit
silent while it works reports through `CLIProgress`, which paints a header, a
row per phase as it lands, a summary, and a spinner for the work in flight that
is rewritten in place and cleared when that work ends. `ed usage refresh` uses
all of it, phases and summaries included, and `ed tools install` prints a header
and streams each line the installer emits. `ed tools ls`, `ed cleaner scan`,
`ed cleaner clean`, `ed machines files get`, `ed machines files put` and `ed app
relaunch` use the spinner alone to name what they are on, with the two transfers
counting bytes against the total. None of it touches stdout, and it is switched
off whole rather than trimmed when there is nobody to watch it: `--json` turns
it off, and so does stderr not being a terminal, `NO_COLOR` being set, or `TERM`
being `dumb`. A piped or redirected run therefore sees none of it, and no
spinner or escape sequence lands in a log.

On a non-zero exit, stdout is empty. That is a contract rather than a habit, and
it is pinned by the same test that pins the exit codes: a command that fails
never leaves half a document behind, so `ed usage summary --json > out.json`
either writes a whole document or writes nothing.

`ed machines exec`, and the `ed <machine> <command...>` shorthand for it, keeps
the remote process's two streams apart on the way through: its stdout arrives on
your stdout and its stderr on your stderr, unlabelled and unbuffered, which is
what makes the shorthand usable in a pipeline. The CLI suspends while that
process runs and resumes from its termination event, so it does not occupy a
cooperative thread or poll for process completion.

Commands that wait for a reply from the running app suspend until the reply,
the deadline, or cancellation. They do not poll on a timer. The one-second
`waiting for Edith to answer...` note and each command's existing timeout are
unchanged, and the notification observer and both pending timers are removed as
soon as the wait finishes.

## Exit codes

There are five, and nothing else is a documented code. A test pins the set to
exactly `0, 1, 2, 3, 4`.

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | success | The command did what it was asked. A dry run that changed nothing on purpose is also 0. |
| 1 | failure | The command was understood and refused or could not finish: a value that failed validation, a write to a read-only setting, a remote command that exited non-zero, a broadcast where at least one machine failed. |
| 2 | usage | The command line was wrong: an unknown flag, a missing argument, an unparseable value, or a number outside what the option accepts. |
| 3 | notFound | The thing you named does not exist, or names more than one thing: an unknown machine, an ambiguous machine prefix, an unknown setting key, permission, guide topic, shell, usage range or app action. |
| 4 | unavailable | The thing you named exists but cannot be reached or acted on right now: the app is closed, an extension is off, a grant is missing, a machine is down, docker is not usable, or the store you asked to read is empty. |

Two enums hold these numbers, `ExitCodes` for the process and `CLIFailure.Kind`
for the errors commands throw, and they are kept numerically identical by hand.
A failure's kind is its exit code: `CLIFailure.notFound(...)` is exit 3, with no
mapping table in between.

**0** is what falling off the end of a command means. Nothing calls `exit(0)`;
the top level only calls `exit` from its `catch`, so a body that returns
normally exits 0. `--help` on any command and `--version` on the root also exit
0, and their text goes to stdout, because the argument parser signals them as a
clean exit and the top-level reporter prints a clean exit's message on stdout
rather than on stderr.

**1** is the default kind. `CLIFailure("...")` with no kind named is a 1, and so
is any error that is neither a `CLIFailure` nor an `ExitCode`: `execute` catches
it, prints `error: ` followed by its localized description on stderr, and
exits 1.
`ed machines broadcast` exits 1 when any machine failed, and a remote command
run for its text rather than its stream exits 1 with the machine's own stderr as
the hint. A setting value that is the wrong type or outside the allowed set is
also 1 rather than 2, because the command line was well formed and the value was
the thing that was wrong.

**2** covers both halves of a bad command line. The argument parser produces it
for a flag it does not know or an argument it cannot parse, and the numeric
checks produce it after parsing for a value it will not accept: `--interval 0`,
`--limit -1`, a fraction outside `0` to `1`. The parser's own failure code is
`EX_USAGE`, which is 64 on macOS, and the top level remaps exactly that value to
2, so an unknown flag exits 2 and never 64.

**3** is the code for a name. Machines resolve through one function and it
throws 3 in three places: no machines are configured at all, the query matches
more than one machine, or it matches none. An unknown config key, permission,
app action, guide topic, completion shell, `--range` value and `--source` name
are the same code from the same shape of check, and the hint carries the
candidates.

**4** is wider than "the app is closed", which is only its most common cause. It
is also the code for an empty store, because an empty store is something you
cannot act on rather than something that failed: no clipboard history yet, an
empty shelf, an empty download queue, no limits collected yet, no workspaces
saved, no music folder chosen. It is also the code for a machine that will not
answer, for docker that is missing or unreachable on the far side, for a usage
refresh whose pipeline failed and an install that did not leave the tool on
`PATH`, and for every branch of the app-silence diagnosis below.

### The passthrough exception

`ed machines exec` propagates the remote process's own exit status rather than
flattening it into one of the five. So does the `ed <machine> <command...>`
shorthand, and so do `ed machines docker logs` and `ed machines docker compose
logs`, which stream another program's output for as long as it runs. An
`ExitCode` thrown by a command reaches the process untouched, so these are not
clamped to `0` through `4`:

```
$ ed tuf test -f /etc/nope
$ echo $?
1

$ ed tuf sh -c 'exit 42'
$ echo $?
42
```

Everything else in `ed machines` is a normal command with normal codes. A
machine that cannot be reached is 4 whatever you were trying to run on it,
because that failure happens before the remote process exists.

## How a failure is reported

A failure is a `CLIFailure`: a kind, a message, and an optional hint. Printing
one is always `CLIOut.report`, which writes the message to stderr and then the
hint, the second only when there is one:

```
error: <message>
hint: <hint>
```

The message says what happened in lower case and without a full stop. The hint
is a next step, and more often than not it is a command you can run or the list
of things you could have named instead.

Both go through `CLIOut.labelled`, which is what keeps a multi-line failure
readable. Remote output often arrives as several lines, and only the first one
carries the label; the rest are indented to line up underneath it, by exactly as
many spaces as the label is wide. So continuation lines sit under `error: ` at
seven spaces and under `hint: ` at six:

```
$ ed machines power reboot tuf --yes
error: Asus TUF 7 did not reboot: sudo: a password is required
       Call to Reboot failed: Interactive authentication required.
hint: give this account passwordless sudo for systemctl on Asus TUF 7
```

`labelled` also tidies what it is given: every line is trimmed of surrounding
whitespace, and blank lines are dropped rather than printed as a bare indent.
A message with no content left after that collapses to the label on its own,
`error:` with nothing after it, rather than a label followed by emptiness.

The plumbing behind that is worth knowing, because it is what keeps the output
identical no matter where the failure came from. Nearly every command body is
wrapped in `execute`, which catches a `CLIFailure`, reports it, and rethrows it
as an `ExitCode` carrying the kind's number. An `ExitCode` that is already
travelling passes through untouched. Anything else becomes `error:` plus its
localized description, and exit 1.

At the top level the same error is seen a second time, and this is where the
double print is prevented: a `CLIFailure` is reported, an `ExitCode` prints
nothing at all because `execute` has already reported it, and anything left is
the argument parser's own message, which goes to stderr when the resolved code
is non-zero and to stdout when it is zero.

A handful of commands do not wrap their body in `execute`: `ed schema`,
`ed version`, `ed uninstall`, `ed config export`, `ed extensions ls`,
`ed machines ls`, `ed system disks` and `ed permissions ls`. Their failures
escape to the top level instead, where they get the identical treatment, so the
difference is invisible from outside.

## Discover, then act

Nothing in `ed` asks you to guess a name, and every list that tells you the
valid names is cheap and needs nothing running:

```
ed machines ls            every configured machine, and whether the socket is live
ed config ls              every setting, its group, its type and its current value
ed config describe <key>  the type, the allowed values and the default, before you write
ed extensions ls          extension ids, and which are on
ed permissions ls         permission ids, and what the app last observed
ed usage sources          the agents that produced the usage history
ed cleaner categories     the cache categories the cleaner knows
ed tools ls               the command line tools and whether they are installed
ed app actions            the one-shot actions, what each needs, and whether it can run now
```

Where a name is forgiving, it is forgiving in a defined order rather than
fuzzily. A machine resolves by exact name, then by ssh config alias, then by
UUID, then by a unique prefix, all case-insensitively. A prefix that matches
more than one machine exits 3 and lists the matches rather than picking one, and
an unknown name exits 3 and lists the machines that do exist. A config key that
does not exist exits 3 and offers the keys that contain what you typed.

Two commands answer the "can I do this right now" question without failing.
`ed version --json` and `ed permissions ls --json` both carry an `appRunning`
field, and `ed app actions` reports each action's `needs`, either `menuBar` or
`mainApp`, alongside an `available` flag. Read one of those first rather than
firing a command to find out whether it would have worked.

## Flags and values

Long options take their value as the next word or after an equals sign, so
`--limit 5` and `--limit=5` are the same. Short forms exist only where they were
declared, and there are only three: `-f` for `--follow` on `ed system stats`,
`ed machines metrics`, `ed machines docker logs` and `ed machines docker compose
logs`; `-a` for `--all` on `ed machines docker ps` and `ed machines files ls`;
and `-t` for `--tty` on `ed machines exec`.

Boolean flags are presence only. There are no `--no-` inversions anywhere, so a
flag is either passed or not. The words `on`, `off`, `true`, `false`, `yes`,
`no`, `1`, `0`, `enabled` and `disabled` are parsed as setting values, by
`ed config set` and by `ed music shuffle` and `ed music repeat`, and never as
flag values.

Options that repeat collect their values: `--source` and `--machine` on `ed
usage summary`, `daily` and `models` narrow to several agents, and `--root` on
`ed cleaner scan` and `clean` sweeps several folders. Everything else takes its
last value.

Numbers are checked twice. The parser rejects text that is not a number, which
is exit 2, and the command then runs the value through one of four checks,
non-negative, positive integer, positive double, or a fraction between 0 and 1,
each of which throws a usage failure, which is also exit 2. So `--interval 0`
and `--interval fast` fail the same way and produce the same code.

`--` ends option parsing. `ed machines exec` and the `ed <machine>
<command...>` shorthand capture everything after it verbatim, which is how a
remote command keeps its own flags:

```
ed machines exec tuf -- ls -la /srv
ed tuf ls -la /srv
```

`--help` is generated for every command, prints to stdout and exits 0.
`--version` exists on the root only.

### Shared options

There are exactly two option groups in the whole CLI, and everything else that
looks shared is a flag declared again on each command.

`--player` comes from the player group and appears on eight commands:
`ed music status`, `play`, `pause`, `stop`, `toggle`, `next`, `previous` and
`volume`. It takes `builtin`, `spotify` or `apple`, and leaving it out means
whichever player is active. An unknown name exits 3.

`--range`, `--source` and `--machine` come from the usage window group and
appear on three commands: `ed usage summary`, `daily` and `models`. `--range`
takes `today`, `week`, `month` or `all` and defaults to `all`; an unknown range
exits 3 with the valid ones listed. `--source` and `--machine` repeat and are
unset by default, and a source or a machine the collected history has never seen
exits 3 and points at the ones it has. `ed usage projects` is the odd one out:
it declares its own `--range` with the same default and takes neither `--source`
nor `--machine`.

Because the rest are re-declared per command, a flag with the same name can have
a different default and a different validator in two places. `--limit` is the
one to watch:

```
ed clipboard ls --limit <n>            25 by default, 0 means all of them
ed download ls --limit <n>             25 by default, 0 means all of them
ed color ls --limit <n>                25 by default, and 0 means all of them here too
ed usage projects --limit <n>          25 by default, and must be greater than zero
ed app updates --limit <n>             20 by default, and must be greater than zero
ed machines files search --limit <n>   300 by default, and must be greater than zero
```

The first two say so in their help. `ed color ls` accepts `0` and behaves the
same way without saying so.

`--yes` means the same thing everywhere it appears, on nine commands: `ed
machines rm`, `ed machines power reboot`, `ed machines power shutdown`, `ed
machines files rm`, `ed machines docker volume-rm`, `ed machines docker prune`,
`ed cleaner clean`, `ed apps quit` and `ed music rm`. Where it is required,
leaving it out makes the command report what it would have done, change nothing,
and exit 0, so a missing `--yes` is never an error to handle.

Seven of the nine require it for anything at all. The other two gate only their
irreversible half: `ed apps quit --all` and `ed machines files rm --delete` need
it, while `ed apps quit <app>` and a plain `ed machines files rm`, which only
moves to the Trash, act straight away without asking.

Secrets are never an argument value. `ed machines add` and `ed machines edit`
take `--password-stdin` and `--key-passphrase-stdin`, and read the secret from
stdin, so it cannot land in a process listing or a shell history.

### Arguments

Positional arguments are positional in the order the synopsis shows them, and
three shapes recur. `<machine>` is declared 58 times across the tree, always
with the same help text, and always resolves the same way through the same
function. An index is always 1-based and always counts in the order the matching
`ls` printed, whether it is a clipboard entry, a shelf item, a download, a saved
forward, a snippet or a pane. A `<path>` on a `machines files` command is a
remote path and a `<local>` is a local one, and `cp`, `mv` and `rm` take several
of them before the destination, like the shell tools they mirror.

Completion is served by a hand-maintained mirror of this whole tree rather than
by the parser, so adding a flag means adding it in two places. If a flag
completes but does not parse, or parses but does not complete, that mirror is
where the two disagree.

## What needs the app running

Edith is two processes with two bundle ids, and the distinction matters because
different commands need different ones. The menu bar helper is
`com.pulkit.edith.statusbar` and the main window is `com.pulkit.edith`. `ed`
detects each by asking macOS for running applications with that bundle id, which
is a local question that needs no permission and no round trip.

| Command | Needs | Why |
| --- | --- | --- |
| `ed app clean-keys`, `ed app test-notification`, `ed app open` | menu bar | the helper owns the panel, the keyboard lock and notifications |
| `ed app quit`, `ed app check-updates` | main window | both act on the window, and the updater lives in it |
| `ed calendar ls` | menu bar | the calendar grant belongs to the Edith bundle, not to `ed` |
| `ed permissions request`, `ed permissions refresh` | menu bar | only the bundle can raise a TCC prompt or re-read its own state |
| `ed usage limits --refresh` | menu bar | only the app polls the providers again; without `--refresh`, `limits` reads the file |
| `ed apps quit` | menu bar | quitting another app is the app's Automation grant, not `ed`'s |
| `ed music start`, `ed music seek` | menu bar | both drive Edith's own player, which lives in the helper |
| `ed music play`, `pause`, `stop`, `toggle`, `next`, `previous`, `volume` | menu bar, only for Edith's own player | against Spotify or Apple Music these go through AppleScript and need only that app |
| `ed machines files undo` | main window | the undo history belongs to an open Finder window and lives in memory |
| `ed app relaunch` | no, but the app must be installed | it terminates both bundle ids, waits, escalates to a force quit, then launches; exits 4 when it cannot find a bundle and 1 when the quit or the launch fails |
| `ed config`, `ed extensions`, `ed schema`, `ed guide`, `ed version`, `ed install`, `ed uninstall`, `ed completions` | no | defaults and files; a write reaches a running app live |
| `ed usage limits`, `summary`, `daily`, `models`, `projects`, `sources` | no | they read the collected files the dashboard reads |
| `ed usage refresh` | no | it runs the collection pipeline in this process, and attaches to the app's run when one is already going |
| `ed usage machines ls`, `enable`, `disable` | no | the machine directory and one defaults key |
| `ed usage machines collect`, `forget` | no | the collector runs over SSH from this process, and the fold back into `usage.json` is the same in-process pipeline `ed usage refresh` runs |
| `ed system stats`, `ed system disks` | no | the same sampler, run in this process |
| `ed clipboard`, `ed color`, `ed shelf`, `ed download`, `ed cleaner` | no | stores under Application Support and the shared defaults suite |
| `ed apps ls`, `ed tools ls`, `ed app actions`, `ed app updates`, `ed app clear-updates` | no | the process table, `PATH`, and a log file |
| `ed tools install` | no | it fetches and installs the tool itself, then checks the tool landed on `PATH` |
| `ed music ls`, `mkdir`, `mv`, `rename`, `rm`, `rescan`, `shuffle`, `repeat`, `status`, `players` | no | the library is a folder of files and two defaults keys |
| `ed machines`, and `ed <machine> <command...>` | no, except `files undo` | `/usr/bin/ssh` over a ControlMaster socket shared with the app |

Anything in the "no" rows works with Edith closed and keeps working with it
open. Where a change is one the app would want to know about, `ed` posts the
same notification the app posts to itself, so a running app updates immediately
and a closed one picks the change up from disk when it starts.

### How `ed` talks to the app

The bus is `DistributedNotificationCenter`, wrapped in one small type, and the
names are string constants of the form `com.pulkit.edith.<verb>`. There is no
XPC, no socket, no AppleScript aimed at Edith, and neither binary shells out to
the other. The app and `ed` are peers over one shared core, which is why the two
can never drift on what a command means.

Most messages are one-way: a config write posts `settingsChanged`, a machine
change posts `machinesChanged`, a clipboard mutation posts `clipboardChanged`, a
shelf edit posts `shelfChanged`, a download change posts `downloadQueueChanged`,
and `ed app open`, `clean-keys` and `test-notification` post and return. Nothing
is waited for, so these cost nothing when the app is closed.

The rest are request and reply: `ed` registers an observer for the reply, posts
the request, then suspends until the observer hands it an answer. It does not
poll. The deadline is a separate task that sleeps and then cancels the wait, and
the note is a third that sleeps one second and prints
`waiting for Edith to answer...` once, on stderr, unless the answer has already
landed. So a reply that comes back in a millisecond resumes the command in a
millisecond, and a command that waits the full deadline spends it asleep rather
than checking. The deadlines are per command:

```
ed calendar ls                 4 seconds
ed usage limits --refresh      20 seconds
ed app check-updates           60 seconds, or 0.1 with --no-wait
ed machines files undo         20 seconds
ed music status                2 seconds, for Edith's own player
```

`--no-wait`, which only `ed app check-updates` has, does not cancel the request,
it collapses the deadline: the message is still posted and the app still does
the work, `ed` just stops waiting to hear about it and exits 0.

### When the app says nothing

Silence is diagnosed rather than reported as a timeout, and every branch is
exit 4, so the code is stable while the message is specific. The order is fixed
and is checked by a test:

1. The helper is not running: `Edith is not running, so it cannot answer for
   <what>`, with the hint to open Edith and try again.
2. The extension behind the command is off: `the extension behind <what> is
   off`, with the hint to run `ed extensions ls`.
3. macOS has not granted the permission the command needs: `macOS has not
   granted Edith access for <what>`, with the hint to run `ed permissions
   request <permission>`.
4. None of the above: `Edith did not answer for <what> in time`, with the hint
   that the running app may predate the command and should be rebuilt and
   reopened.

`ed calendar ls` goes one step further and reads the status the app sent back,
so an app that answers and says the extension is off, or that the calendar grant
is missing, produces the specific message rather than the generic one. Both are
still exit 4.

Three commands deliberately do not fail when the app is closed. `ed download
add` and `ed download retry` write the queue either way and note on stderr that
`Edith is not running, so this starts when you next open it`, then exit 0. The
work is queued rather than lost, so failing would be wrong. `ed download cancel`
empties the queue either way too, and with Edith closed it notes that `Edith was
not running, so the queue was emptied without stopping yt-dlp` rather than
claiming it stopped a transfer.

## Where to go next

- [`ed machines`](./machines/README.md) for the SSH transport, and the one command in
  the group that needs the app.
- [`ed app`](./app/README.md) for the one-shot actions and which process each needs.
- [`ed permissions`](./permissions/README.md) for why the grants belong to the bundle
  rather than to `ed`.
- [`ed usage`](./usage/README.md) for the commands that read files, the one that
  collects them again, and the one that asks the app.
- [All command pages](./README.md).
