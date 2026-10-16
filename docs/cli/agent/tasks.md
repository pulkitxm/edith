# `ed agent tasks`

Submits and inspects work owned by the daemon. Closing the submitting app or CLI
does not discard accepted work. `ed agent tasks` defaults to `ed agent tasks ls`.

```text
ed agent tasks ls [--json]
ed agent tasks inspect <id> [--json]
ed agent tasks cancel <id> [--json]
ed agent tasks exec [--json] [--detach] [--timeout 300] -- /absolute/executable [arguments...]
```

`ed agent tasks exec` requires `--` before an absolute executable path. Everything
after that separator belongs to the child command, including `--help` and
`--json`. Without `--detach`, the CLI waits and returns the child's exit code.
`--detach` returns the accepted task UUID immediately. JSON returns the task
snapshot when detached, or the completed command result when waiting.

`ed agent tasks inspect` returns the snapshot, retained output and result.
`ed agent tasks cancel` requests cancellation and returns the resulting snapshot.
Inspect again to distinguish stopping from final cancellation. Queued work can
be cancelled before it starts, and running commands stop their owned process group.

The daemon bounds queue concurrency and retained output. Active work interrupted
by daemon restart remains inspectable as interrupted, while completed results stay
available. Cancellation does not roll back a command's earlier external effects.

```sh
ed agent tasks exec --detach --json -- /bin/sh -c 'sleep 2; printf "finished\n"'
ed agent tasks ls --json
ed agent tasks inspect 11111111-1111-1111-1111-111111111111 --json
```

- [`ed agent`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
