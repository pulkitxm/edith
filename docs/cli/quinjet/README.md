# `ed quinjet`

Discover and open Quinjet review workspaces through the same client, worktree
selection and launch-request builder as Edith's Quinjet page. Discovery can run
against this Mac or one configured SSH machine.

`ed quinjet` defaults to `ed quinjet projects`. A local or remote Quinjet CLI
must be installed and able to return its current JSON format. The Edith Quinjet
extension does not have to be enabled.

## At a glance

| Command | What it does |
| --- | --- |
| `ed quinjet projects` | List recent projects and their worktrees |
| `ed quinjet worktrees <path>` | List every worktree for a project or worktree path |
| `ed quinjet open <path>` | Print the exact launch command without running it |
| `ed quinjet launch <path>` | Run Quinjet in the current terminal or cmux |

## Targeting

Every command accepts `--machine <name>`. Omit it, or use `--machine local`, for
this Mac. A configured machine name, SSH alias, UUID or unique prefix resolves
through Edith's machine directory. The command connects through Edith's shared
SSH control socket and gives that socket to Quinjet for remote discovery and
launch.

```sh
ed quinjet projects --json
ed quinjet projects --machine build --json
ed quinjet worktrees /srv/edith --machine build --json
```

A machine that is asleep or unreachable exits 4 before discovery. An unknown
machine exits 3.

## Planning and launching

`ed quinjet open` is print-only. It resolves the requested project, chooses the
current or first available worktree, constructs the launch request and prints a
shell-quoted command. It never starts a process or sends AppleScript.

`ed quinjet launch` crosses the execution boundary. The default replaces the
current command with an interactive Quinjet process attached to the same
standard input and output. `--cmux` asks cmux to create a workspace instead.

```sh
ed quinjet open ~/code/edith
ed quinjet open ~/code/edith --theme tokyo-night --appearance light
ed quinjet launch ~/code/edith
ed quinjet launch ~/code/edith --cmux
ed quinjet launch /srv/edith --machine build --theme gruvbox
```

Both commands accept these options:

| Name | Values | Default | What it does |
| --- | --- | --- | --- |
| `--theme <name>` | `quinjet`, `catppuccin`, `dracula`, `everforest`, `gruvbox`, `nord`, `one`, `rose-pine`, `solarized`, `tokyo-night`, `ayu`, `monokai`, `github` | `quinjet` | Select the Quinjet theme |
| `--appearance <value>` | `light`, `dark` | `dark` | Select the theme appearance |
| `--cmux` | flag | off | Build or run a cmux launch request |
| `--machine <name>` | configured machine or `local` | `local` | Select the worktree host |
| `--json` | flag | off | Emit stable JSON on stdout |

cmux must be installed in `/Applications` or `~/Applications`. If it is not,
`launch --cmux` exits 4 with a hint to omit `--cmux`. `open --cmux` remains safe
and prints the cmux-targeted Quinjet command without asking cmux to run it.

## JSON

`projects --json` returns `local`, `machine` and `projects`. Each project has
`commonDir`, `name` and `worktrees`. `worktrees --json` returns `local`,
`machine` and `worktrees`.

A worktree object has these stable keys: `bare`, `branch`, `canOpen`, `current`,
`detached`, `displayName`, `head`, `locked`, `path` and `prunable`. Nullable
values are JSON null. Object keys are sorted.

`open --json` and `launch --json` return `arguments`, `command`,
`currentDirectory`, `executable`, `launched`, `local`, `machine`, `terminal` and
`worktree`. `launched` is false for `open` and true after a successful `launch`.
`terminal` is `current` or `cmux`.

For `launch --json`, the child process cannot write to stdout and receives no
interactive input, so stdout remains exactly one JSON document. Use plain
`launch` for an interactive terminal session. Use `open --json` for a safe
noninteractive preview, or `launch --cmux --json` to open a separate workspace.

## Exit codes

| Code | When |
| --- | --- |
| 0 | Discovery, planning or launching succeeded |
| 1 | Quinjet failed, returned malformed JSON or exited unsuccessfully |
| 2 | Arguments, theme or appearance were invalid |
| 3 | The machine or an openable worktree was not found |
| 4 | Quinjet, cmux or the selected machine was unavailable |

A missing Quinjet executable includes the Homebrew install command. A failed
Quinjet command includes its diagnostic. Malformed JSON suggests updating
Quinjet and retrying.

## Where to go next

- [`ed machines`](../machines/README.md) for configured SSH machines
- [`ed extensions`](../extensions/README.md) to show the Quinjet page in Edith
- [All `ed` commands](../README.md)
