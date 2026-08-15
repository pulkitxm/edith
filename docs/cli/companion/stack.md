# `ed companion stack`

Starts, stops and inspects the companion stack on whichever machine
[`ed companion deploy`](./deploy.md) put it on.

Usage:

```
ed companion stack <subcommand>
```

| Command | What it does |
| --- | --- |
| `ed companion stack status` | Which host runs it, and which services are up. |
| `ed companion stack up` | Starts it. |
| `ed companion stack down` | Stops it. |
| `ed companion stack restart` | Restarts it. |
| `ed companion stack logs` | Reads its logs. |
| `ed companion stack env` | Prints the environment it would be given. |

`status` is the default subcommand.

## `ed companion stack status`

```
$ ed companion stack status
running on TUF Wired, cpu, reached on port 4820
SERVICE   STATUS                      PORTS
api       Up 28 minutes               127.0.0.1:4820->4820/tcp
postgres  Up About an hour (healthy)  127.0.0.1:5432->5432/tcp
redis     Up About an hour (healthy)  127.0.0.1:6379->6379/tcp
```

Takes `--json`.

## `ed companion stack up`

Takes `--build` to rebuild the api image first, and `--json`.

## `ed companion stack down`

Takes `--wipe` to delete the volumes as well, which destroys stored memory, and
`--json`. Without it the data survives.

## `ed companion stack restart`

Takes `--json`.

## `ed companion stack logs`

```
ed companion stack logs [<service>] [--tail <n>] [--json]
```

Reads the whole stack's logs, or one service's. `--tail` defaults to 100.

## `ed companion stack env`

Prints the environment file the stack is given, rendered from your
configuration. Secrets are blank unless `--reveal` is passed, because they live
in the Keychain and never in the config file. Takes `--json`.

## Where to go next

- [`ed companion hosts`](./hosts.md) lists where it could run.
- [`ed companion doctor`](./doctor.md) checks it once it is up.

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
