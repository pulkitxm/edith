# The `ed` command line

`ed` is the command line for Edith. It ships inside the app, links itself onto
your `PATH` the first time the app runs, and reaches everything the UI reaches:
settings, extensions, permissions, agent usage, this Mac's metrics, playback,
your clipboard, your calendar, and the machines Edith can talk to over SSH.

`edh` and `edith` are the same binary under different names. Every example in
these pages works with any of the three.

The built-in manual is `ed guide`, which is written for agents and humans alike
and is the shortest path to being useful. These pages are the complete
reference: one page per command group, every flag, every default, every JSON
key.

## Start here

| Page | What it covers |
| --- | --- |
| [Getting started](./getting-started/README.md) | Installing and linking the CLI, `ed guide`, `ed schema`, `ed version`, shell completion, and the `ed <machine> ...` shorthand |
| [Conventions and contracts](./conventions.md) | The `--json` guarantee, stdout versus stderr, the exit code table, and which commands need the app running |

## This Mac

| Page | What it covers |
| --- | --- |
| [`ed config`](./config/README.md) | Every setting the UI exposes, and the full setting catalogue |
| [`ed app`](./app/README.md) | One-shot app actions, section reveal, and PNG window snapshots |
| [`ed extensions`](./extensions/README.md) | Turning Edith's features on and off |
| [`ed lid-awake`](./lid-awake/README.md) | Closed-lid sessions, battery auto-pause and live state |
| [`ed permissions`](./permissions/README.md) | Inspecting and requesting Edith's macOS permissions |
| [`ed usage`](./usage/README.md) | Agent usage: limits, cost, tokens, projects, sources, and machine attribution |
| [`ed system`](./system/README.md) | CPU, memory, load, network and mounted volumes |
| [`ed music`](./music/README.md) | Playback control and the local music library |
| [`ed calendar`](./calendar/README.md) | Your agenda |
| [`ed clipboard`](./clipboard/README.md) | Clipboard history: read, copy, pin and prune |
| [`ed color`](./color/README.md) | The colour picker's swatch history |
| [`ed download`](./download/README.md) | The download queue and the tools that back it |
| [`ed apps`](./apps/README.md) | Running applications, and quitting them |
| [`ed tools`](./tools/README.md) | The command line tools Edith can install for you |
| [`ed shelf`](./shelf/README.md) | The notch shelf's staged files |
| [`ed cleaner`](./cleaner/README.md) | Scanning and reclaiming disk space |
| [`ed companion`](./companion/README.md) | Local memory health, status, Markdown ingest and episodes |

## Other machines

| Page | What it covers |
| --- | --- |
| [`ed machines`](./machines/README.md) | The machine directory: add, edit, connect, inspect, plus snippets and forwards |
| [Running commands on a machine](./machines-remote/README.md) | The `ed <machine> ...` shorthand, `ed machines exec`, remote working directories and completion |
| [`ed machines docker`](./machines-docker/README.md) | Containers, images, volumes, networks and compose projects |
| [`ed machines files`](./machines-files/README.md) | Browsing, transferring and editing files over SSH, and the undo model |
| [`ed machines power`](./machines-power/README.md) | Power state, processes and system services |
| [`ed machines workspace`](./machines-workspace/README.md) | Workspaces and panes |

## The short version

```
ed guide                         the built-in manual
ed config ls                     every setting and its current value
ed lid-awake on --for 30m        keep running with the lid closed for 30 minutes
ed usage limits --json           the numbers behind the rate-limit rings
ed system stats --follow         this Mac, sampled continuously
ed machines ls                   the computers Edith can reach
ed tuf docker ps                 run anything on one of them
```

Every reporting command that advertises `--json` prints exactly one document on
stdout, except the two documented streaming modes. Errors, hints and notes go
to stderr. Exit codes are part of the contract, so an agent can drive Edith
headlessly. See
[conventions and contracts](./conventions.md) for the details.

These pages are mirrored to the [wiki](https://github.com/pulkitxm/edith/wiki)
on every push to `main`. Edit the files here, never the wiki.
