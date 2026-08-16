# `ed machines docker start`

Starts a stopped container.

```
ed machines docker start [--json] <machine> <container>...
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to act on. |
| `<container>...` | one or more container names or ids | at least one required | Which containers to start. Docker is given all of them in one call. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the one-line confirmation. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

Human output is one line, `start <container>`.

## `--json` shape

```json
{
  "action": "start",
  "containers": [
    "open-webui"
  ],
  "machine": "Asus TUF 7"
}
```

`machine` is the machine's display name as Edith stores it, not what you typed.
`containers` echoes back exactly what you typed, in the order you typed it, so
passing a short id gives you a short id here. Naming no container at all exits 1
with `name at least one container`, before the machine is dialled.

## Examples

```
ed machines tuf docker start open-webui
ed machines tuf docker start b556d7fef23e --json
ed machines tuf docker start api postgres redis
```

## Behaviour notes

Runs `docker start <container>...` with a 120 second ceiling, one call however
many containers are named. A docker that refuses exits 1, with docker's own
stderr as the hint:

```
$ ed machines tuf docker start nosuch-container
error: docker start failed on Asus TUF 7
hint: Error response from daemon: No such container: nosuch-container
failed to start containers: nosuch-container
```

Naming several containers is all or nothing in the exit code only. Docker starts
the ones it can and reports the rest on stderr, so a call that names three and
fails on one exits 1 having started the other two; the hint names which one
failed. Re-read the states with `ed machines docker ps --all` rather than
assuming nothing happened.

A container whose published port is already taken by something else is the case
worth knowing about, because it does not always fail. Docker sometimes refuses
outright, with `Bind for 127.0.0.1:6379 failed: port is already allocated`, and
sometimes exits 0 having left the container `running` with no network attached
and no ports published at all. `ps` reports that container as running with an
empty `ports` array, so a group that looks healthy can still have a service
nothing can reach. `ed machines docker inspect <container>` settles it: an empty
`NetworkSettings.Networks` is a container that came up without its network.

This is the Docker window's start button, running the same command, and naming
several containers is what the play button on a group header does. That button
names the group's stopped containers, and appears whenever at least one of them
is stopped, so a group with some containers up and some down shows a play button
and a stop button side by side. Paused containers are never named here, because
`docker start` refuses them and one refusal fails the whole call.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
