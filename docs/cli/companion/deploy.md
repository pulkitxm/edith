# `ed companion deploy`

Chooses the machine that runs the companion, brings the stack up there, and
remembers the choice so everything else knows where it lives.

Usage:

```
ed companion deploy [<machine>] [--directory <path>] [--port <n>] [--adopt] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--directory` | path | `~/edith-companion` | Where the stack runs on that machine. |
| `--port` | number | 4820 | Local port the API is reached on. |
| `--adopt` | flag | off | Records a stack that is already running without starting anything. |

With no machine argument it uses the one that already hosts the stack, or the
best candidate that can run it.

An explicit machine argument selects a remote registered machine by exact
case-insensitive name, UUID, or text contained in its SSH target. It does not
accept name prefixes and cannot explicitly select this Mac; omit the argument
when the local host is the recommended candidate.

Examples:

```
$ ed companion deploy "TUF Wired"
the companion running on TUF Wired, cpu, reached on port 4820

$ ed companion deploy "TUF Wired" --adopt
the companion running on TUF Wired, cpu, reached on port 4820
```

A machine that cannot run it yet is refused with the reason and the fix, so
nothing half-starts. The tier is derived from the Mac processor: Apple silicon
uses the Apple Metal overlay and Intel uses CPU.

Deploying creates the directory and looks for companion source in
`EDITH_COMPANION_SOURCE`, `~/Desktop/Edith/apps/companion`, then
`~/edith/apps/companion`. When found, it streams a tarball that excludes
`target` and `.git` into the destination on every deploy. When no local source
is found, an existing destination must already contain `Cargo.toml` or deploy
fails before Compose starts.

The CLI then overwrites its carried Compose files and Dockerfile, writes `.env`
with mode controlled by `umask 077`, and includes the current configuration and
Keychain secrets. `--port` must be positive and is written as the API port as
well as saved for endpoint resolution. The stack starts with `up -d --build`.
The deployment record is saved only after that command succeeds.

For a remote host, deploy reuses or creates a forward from the chosen local
port to the same remote port. A tunnel failure is a note, not a failed deploy,
so run `ed machines forwards on <machine>` yourself if status cannot connect.
The CLI does not wait for `/v1/health` before returning; use
[`ed companion doctor`](./doctor.md) to verify the completed startup.

`--adopt` skips installation, `.env` writes, Compose startup and tunnel setup.
It only saves the selected host, directory, tier and port. Before adopting, the
CLI accepts either a host that passes readiness or one whose Compose service
list is already nonempty. It does not verify API health.

`--json` emits the saved deployment object:
`{machineName,isLocal,directory,tier,localPort,endpoint,deployedAt}`. Progress
notes from a real deploy remain on stderr.

## Where to go next

- [`ed companion hosts`](./hosts.md) shows the candidates first.
- [`ed companion stack`](./stack.md) drives it once it is deployed.

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
