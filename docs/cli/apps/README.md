# `ed apps`

`ed apps` is the System page's Running apps card on stdout: what is running on
this Mac right now, and a way to quit any of it, one app at a time or
everything at once. Reach for it when you want the list without opening a
window, or when a script needs a quiet desktop before something noisy runs.

The two verbs sit on opposite sides of a line. Listing reads the process table
directly and needs nothing. Quitting cannot be done by `ed` at all: sending a
quit event is Automation, and that grant belongs to the Edith bundle rather
than to a command line process, so `ed` asks the menu bar app to send it and
exits 4 when Edith is closed.

## At a glance

| Command | What it does |
| --- | --- |
| `ed apps ls` | Lists every app with a Dock presence, with its pid and bundle id. Runs when you type `ed apps` with no subcommand, and answers to `ed apps list`. |
| `ed apps quit` | Asks Edith to quit one app by name, bundle id or prefix, or everything except Finder and Edith with `--all`. |

## Commands

- [`ed apps ls`](./ls.md)
- [`ed apps quit`](./quit.md)

## Exit codes

| Code | When |
| --- | --- |
| 0 | The list was printed, the count was reported, or the quit request was posted. `--help` and `--version` also exit 0. |
| 1 | `ed apps quit` was given neither an app name nor `--all`, or was given both. |
| 2 | The command line was wrong in the ordinary way: an unknown flag, a second positional argument, or a value the parser could not read. |
| 3 | The named app is not running, or the name is a prefix that matches more than one running app. |
| 4 | `ed apps quit` was run while the Edith menu bar app was not running. Every form is affected, including the `--all` dry run. |

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
- Nothing completes an app name. `ed apps quit <TAB>` offers nothing at all,
  because the completion tree declares that argument free-form and the engine
  only proposes flags once the word you are on already starts with a `-`, so
  `ed apps quit -<TAB>` is the one that lists `--all`, `--force`, `--yes`,
  `--json` and `--help`. `ed apps ls` is the discovery step.
- The two argument errors on `quit` exit 1 rather than 2 even though they read
  like usage errors. Gate on 1 as well as 2 if you are distinguishing a bad
  command line from a real failure.
- Order of checks beats specificity of message. With Edith closed,
  `ed apps quit nosuchapp` exits 4 rather than 3, because the app check runs
  before the name is resolved. Start Edith before trusting a 3 or a 4 from this
  command to mean what it says.
- The `--all` preview is not free of the app requirement either. It counts
  nothing and posts nothing, but it still exits 4 when Edith is closed.
- The count `--all` prints is computed by `ed` and the quitting is done by the
  helper a moment later against its own fresh list. An app launched or closed in
  between changes what happens without changing what was printed.
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
- The UI path and the CLI path funnel through the same `RunningApps` helper, so
  the System page's per-row quit button, its `Quit all apps` header button and
  these commands cannot disagree about what is protected or about what `--force`
  means. The difference is which process runs it: the UI quits from the main
  window's process, `ed` quits from the menu bar helper's.
- The UI asks before it acts, with a confirmation dialog naming the app or the
  count. `--yes` is the command line's version of that dialog, and it exists
  only for `--all`. A single named app quits without any confirmation.

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
