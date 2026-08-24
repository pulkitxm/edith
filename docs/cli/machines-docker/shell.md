# `ed machines docker shell`

Opens an interactive shell in a container on a configured machine.

```text
ed machines docker shell <machine> <container>
```

| Argument | Meaning | Required | Notes |
| --- | --- | --- | --- |
| `<machine>` | machine name, SSH alias or id | yes | Must resolve to exactly one configured machine. |
| `<container>` | container name or id | yes | Passed to Docker as one quoted argument. |

The command checks that the machine is reachable and Docker is usable, then
starts an interactive SSH terminal attached to the container. It uses the exact
shell selection used by the Docker window: `bash` when present, otherwise `sh`.
The SSH process owns stdin, stdout and stderr until the shell exits.

There is no `--json` because the result is an interactive terminal. The command
does not use the remembered working directory from `ed machines exec`, since
the shell starts inside the container. Its exit status is the SSH process exit
status. An unknown machine exits 3, and an unreachable machine or unavailable
Docker daemon exits 4.

```text
ed machines docker shell box api
ed machines box docker shell api
```

- [`ed machines docker`](./README.md), the rest of this group
- [The `ed` command line](../README.md), the full command index
