---
name: edith-remote-work
description: Work on projects on external machines from the host laptop through Edith's ed CLI. Use when exploring remote projects, editing files, running builds or tests, managing containers, or using a requested remote harness on machines already registered in Edith.
---

# Edith Remote Work

Keep the current harness on the host laptop. Perform remote project work through
`ed`, using Edith's existing machine directory and connections. A terminal tool
on the host launches `ed`; the command after the machine selector runs remotely.

## Discover the working context

Start with `ed machines ls --json` to discover configured machines. Use
`ed guide`, `ed schema` and command-specific `--help` to discover the installed
CLI's capabilities. Do not assume that a machine, project path, operating
system, container tool or remote harness exists.

Inspect relevant machines with `ed machines show <machine> --json`. For a broad
project-discovery request, inspect each relevant reachable machine and report
its project paths and any unreachable machines. Start with the remote home and
likely project roots, using bounded directory listings and `rg` when available.
Do not recursively scan entire disks by default.

Select the machine and absolute project path before making changes. Read that
project's AGENTS.md and other applicable repository instructions remotely.
Inspect its branch, worktrees and uncommitted changes. Follow the user's branch
or worktree choice and commit requirements before editing.

## Route commands through Edith

For simple commands, prefix the command with an exact configured machine name
or SSH alias:

```sh
ed <machine> uname -a
ed <machine> git -C /absolute/project status --short
```

For UUIDs, ambiguous names, or names that collide with an Edith subcommand, use
`ed machines exec <machine> -- <command...>`.

On a POSIX remote shell, pass compound commands as one quoted argument so pipes,
redirects, variables and shell operators execute on the remote machine:

```sh
ed machines exec <machine> -- 'cd /absolute/project && git status --short'
ed machines exec <machine> -- 'cd /absolute/project && rg --files | head -80'
```

Replace placeholders with discovered values and quote paths for the remote
shell. Prevent the host shell from expanding remote variables or command
substitutions. Multiple command arguments are quoted individually by Edith;
a single command argument is interpreted by the remote shell. Match syntax to
the remote operating system, using PowerShell where appropriate.

Include `cd /absolute/project && ...` in every compound project command. Do not
rely on `ed <machine> cd`: noninteractive calls share a remembered directory,
and a missing remembered directory can fall back to the remote home.

Read, search, edit, build, test and run Git on the selected machine through `ed`.
Do not use host file-editing tools against a remote path. For multiline edits,
use a correctly quoted remote script or upload a staged file through
`ed machines files put`; discover its argument order from `--help`.
Plain remote execution does not forward stdin, so piping a patch or heredoc
into `ed` will not deliver it remotely. Transfer binary artifacts with Edith's
file commands instead of treating command output as a binary transport.

## Containers, harnesses and long jobs

Use command-specific help to discover Edith's Docker, file, port-forwarding,
and agent integrations. `ed <machine> docker ...` runs the remote Docker CLI;
`ed machines docker ...` uses Edith's structured integration. Follow repository
container conventions, including `ac` where configured.

The current harness can work directly through `ed`; starting another harness is
not required. When the user requests a remote harness, discover its executable,
working-directory options and noninteractive or resume flags on that machine.
Do not mistake `ed agent`, which manages Edith's background service, for a
coding-harness launcher. Do not delegate or launch paid remote work merely
because an integration is available.

Prefer noninteractive execution. Use `ed machines exec --tty <machine> ...`
only when an interactive terminal is needed and the host tool supports one.
Remote execution has no built-in timeout. For persistent jobs, use a discovered
Edith task integration or the project's existing job manager, record its job ID,
and inspect its output through `ed`. Avoid starting duplicate jobs after an
interrupted connection; check whether the original is still running first.

## Verify the result

Plain execution returns remote stdout, stderr and the remote exit code. It does
not accept `--json`; request JSON from the remote program or use an Edith
integration that supports it. Distinguish a command failure from transport
failure using stderr. Never silently fall back to the host laptop or direct SSH
when Edith cannot reach a machine.

Run the relevant checks and the finished workflow on the selected machine.
Report the machine, project path, resulting commits or artifacts, verification
results, and any unresolved failures. Keep work within the user's authorized
scope; machine access alone does not authorize deployment or destructive work.
