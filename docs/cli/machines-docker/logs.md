# `ed machines docker logs`

Streams one container's logs to your terminal.

```
ed machines docker logs [--tail <n>] [--follow] <machine> <container>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to ask. |
| `<container>` | container name or id, full or short | required | Which container's logs to read. Passed to docker as given. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tail` | integer, 0 or more | `200` | How many trailing lines to show. `0` shows none, which is what you want with `--follow`. |
| `--follow`, `-f` | flag | off | Keep streaming until interrupted. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

There is no `--json` here, and no `--since` or `--until`: this is a passthrough
of docker's own output.

```
$ ed machines tuf docker logs lobe-chat --tail 3
2026-08-08T07:38:18.342112977Z Warning: Cannot polyfill `DOMMatrix`, rendering may be broken.
2026-08-08T07:38:18.342116199Z Warning: Cannot polyfill `ImageData`, rendering may be broken.
2026-08-08T07:38:18.342119077Z Warning: Cannot polyfill `Path2D`, rendering may be broken.
```

## Examples

```
ed machines tuf docker logs lobe-chat
ed machines tuf docker logs tuf-api --tail 50
ed machines tuf docker logs open-webui --tail 0 --follow
```

## Behaviour notes

The remote command is
`docker logs --timestamps --tail <n> [--follow] <container>`. Timestamps are
always on and cannot be turned off, which is the one way this differs from
typing `docker logs` yourself.

Output is streamed line by line as it arrives, with the container's stdout going
to your stdout and its stderr going to your stderr, so redirecting one does not
swallow the other. There is no timeout: `--follow` runs until you interrupt it
or the container stops.

This is one of the two verbs on this page that propagate the remote exit code
instead of mapping it into the 0 to 4 table. A container that does not exist is
docker's error, on stderr, with docker's status, usually 1. `--tail` is
validated before anything is sent: a negative value exits 2, though you have to
write `--tail=-1` to reach the check because `--tail -1` is read as a missing
value and exits 2 for that reason instead.

```
$ ed machines tuf docker logs open-webui --tail=-1
error: --tail cannot be negative
hint: pass 0 or more
```

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
