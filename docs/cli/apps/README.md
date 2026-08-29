# `ed apps`

`ed apps` is the System page's Running apps card on stdout: what is running on
this Mac right now, and a way to quit any of it, one app at a time or
everything at once. Reach for it when you want the list without opening a
window, or when a script needs a quiet desktop before something noisy runs.

Listing and quit planning read the process table directly and need nothing.
Applying a quit needs `--yes` and the Edith menu bar helper because confirmed
execution stays in the same app-owned path as the System page.

## At a glance

| Command | What it does |
| --- | --- |
| `ed apps ls` | Lists every app with a Dock presence, with its pid, CPU, memory and bundle id. Runs when you type `ed apps` with no subcommand, and answers to `ed apps list`. |
| `ed apps open` | Opens an installed app by its exact bundle identifier. |
| `ed apps quit` | Previews or applies an exact plan for one app by name, bundle id or prefix, or everything except Finder and Edith with `--all`. |

## Commands

- [`ed apps ls`](./ls.md)
- [`ed apps open`](./open.md)
- [`ed apps quit`](./quit.md)

## Exit codes

| Code | When |
| --- | --- |
| 0 | The list or preview was printed, or Edith acknowledged a confirmed quit request. `--help` and `--version` also exit 0. |
| 1 | `ed apps quit` was given neither an app name nor `--all`, was given both, or named a protected app. |
| 2 | The command line was wrong in the ordinary way: an unknown flag, a second positional argument, or a value the parser could not read. |
| 3 | The named app is not running, or the name is a prefix that matches more than one running app. |
| 4 | A confirmed `ed apps quit --yes` could not reach the Edith menu bar app or the app did not acknowledge it. Previews do not need Edith. |

`ed apps ls` only ever exits 0 or 2. Code 1 is otherwise the catch-all for an
unexpected error escaping either command, and nothing on the listing path throws
one.

## Notes and gotchas

- `ed apps` with no subcommand is `ed apps ls`, and `ed apps list` is the same
  command again. Completion offers `ls` and `quit`; the `list` alias works but
  is not among the candidates.
- `ed app` and `ed apps` are different groups. The singular one acts on Edith
  itself, open, quit, relaunch and update checks; the plural one acts on
  everything else running on the Mac. There is no prefix matching between
  subcommand names, so the two never collide, but the names are one letter
  apart and easy to mistype.
- `ed apps quit <TAB>` completes the current running app names and bundle ids.
  `ed apps quit -<TAB>` lists `--all`, `--force`, `--yes`, `--json`, and
  `--help`.
- The two argument errors on `quit` exit 1 rather than 2 even though they read
  like usage errors. Gate on 1 as well as 2 if you are distinguishing a bad
  command line from a real failure.
- Name resolution and exact target planning happen before the helper check.
  Missing and ambiguous targets remain diagnosable while Edith is closed.
- Every quit without `--yes` is a free preview. It names the exact targets,
  changes nothing, and works while Edith is closed.
- The confirmed command sends the exact PIDs in the plan. The helper does not
  recompute `--all`, so an app launched after planning cannot be included.
- Confirmed commands wait for a correlated helper reply. Exit 0 means Edith
  received the exact plan and reports how many termination requests macOS
  accepted. It does not mean each process has finished closing.
- An empty app name matches every app rather than none, because the empty string
  is a prefix of everything: `ed apps quit ""` exits 3 and lists all of them. It
  is a harmless way to see the resolver's ambiguity message.
- Exact name beats exact bundle id beats unique prefix, and the prefix rule
  applies to names only. `ed apps quit com.spotify` matches nothing even though
  `ed apps quit com.spotify.client` works.
- Object keys are sorted in every document this group emits, so two runs diff
  cleanly. Array order is insertion order, which for `ls` is the name order the
  table shows.
- Both commands see only apps with a Dock presence. Menu bar agents, helpers and
  daemons are invisible to `ls` and unreachable by `quit`, which is also why
  `ed apps quit --all` never touches the menu bar helper it is talking to.
- The UI path and CLI path funnel through the same running-app operation center,
  including resource sampling, protected targets and quit execution. The UI
  quits from the main window process and `ed` asks the menu bar helper.
- The UI asks before it acts, with a confirmation dialog naming the app or the
  count. `--yes` is the command line equivalent for both named and all-app
  quits.

## Where to go next

- [`ed app`](../app/README.md) for acting on Edith itself rather than on other apps,
  including quitting and relaunching it.
- [`ed system`](../system/README.md) for CPU and memory per process on this Mac,
  covering everything running and not only the apps with a Dock icon.
- [`ed machines power`](../machines-power/README.md) for the same idea on another
  machine, where `ed machines kill` signals a remote process.
- [Conventions and contracts](../conventions.md) for the exit code table, the
  `--json` guarantee and the full list of what needs the app running.
- [The `ed` command line](../README.md) for the rest of the reference.
