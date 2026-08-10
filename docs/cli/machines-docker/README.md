# `ed machines docker`

`ed machines docker` is the parsed view of docker on another machine. Every verb
here opens the shared SSH connection, runs one real docker command with
`--format '{{json .}}'` where docker offers it, and turns the answer into stable
fields, so a script never has to scrape a column layout. It is the same set of
operations the app's Docker window performs, running the same commands.

Nothing is installed on the far side and nothing is proxied through the Edith
app: this is `/usr/bin/ssh` over the ControlMaster socket the app shares, so
these commands work with Edith closed. What they need is docker on the machine
and a user who can reach its socket.

There are two ways into docker on a machine, and the difference matters.
`ed machines <machine> docker ps` is this page: parsed, `--json`, stable keys.
`ed <machine> docker ps` is the raw shorthand, which sends the line to the
remote shell verbatim and gives you docker's own output and exit code. Reach for
the raw form for anything this page does not cover, `ed tuf docker buildx ls`
being the usual example.

## At a glance

| Command | What it does |
| --- | --- |
| `ed machines docker ps` | Lists containers merged with live CPU and memory. Runs when you name no subcommand. |
| `ed machines docker images` | Lists images with their size and whether they are dangling. |
| `ed machines docker volumes` | Lists volumes with their driver and mountpoint. |
| `ed machines docker networks` | Lists networks with their driver and scope. |
| `ed machines docker df` | Disk usage by object type, with what is reclaimable. |
| `ed machines docker logs` | Streams one container's logs, with timestamps. |
| `ed machines docker inspect` | Prints docker's own `inspect` JSON, untouched. |
| `ed machines docker start` | Starts one or more containers. |
| `ed machines docker stop` | Stops one or more containers, with a 10 second grace period. |
| `ed machines docker restart` | Restarts one or more containers, with a 10 second grace period. |
| `ed machines docker rm` | Removes one or more containers, killing them first. Destructive, and there is no `--yes`. |
| `ed machines docker pause` | Freezes the processes of one or more containers. |
| `ed machines docker unpause` | Lets one or more frozen containers run again. |
| `ed machines docker rmi` | Removes an image. Destructive. Aliased `remove-image`. |
| `ed machines docker volume-rm` | Removes a volume and the data in it. Destructive, needs `--yes`. |
| `ed machines docker prune` | Reclaims space from unused objects. Destructive, needs `--yes`. |
| `ed machines docker compose ls` | Lists compose projects. Runs when you name no compose subcommand. Aliased `list`. |
| `ed machines docker compose up` | Brings a project up in the background. |
| `ed machines docker compose down` | Takes a project down, removing its containers and networks. Destructive. |
| `ed machines docker compose restart` | Restarts a project. |
| `ed machines docker compose pull` | Pulls the images a project uses. |
| `ed machines docker compose logs` | Streams the whole project's logs. |

## What destroys data, and what guards it

Five verbs remove something, and only `volume-rm` and `prune` ask first. Read
this table before you script any of them.

| Command | What disappears | Guard |
| --- | --- | --- |
| `ed machines docker rm` | The container, killed first with `docker rm -f`. Anything written inside it and not in a volume goes with it. | none |
| `ed machines docker rmi` | The image. With `--force`, even while a container still refers to it. | none |
| `ed machines docker volume-rm` | The volume and every byte in it. This is where databases live. | `--yes` |
| `ed machines docker prune volumes` | Every volume no container currently uses, and their contents. | `--yes` |
| `ed machines docker prune images` | Every image no container uses, not only the dangling ones: the command is `docker image prune -af`. | `--yes` |
| `ed machines docker compose down` | The project's containers and its network. Named volumes survive, because `-v` is never passed. | none |

`prune system`, `prune networks` and `prune builder` remove stopped containers,
unused networks, dangling images and build cache. `docker system prune -f` is
what runs for `system`, without `--volumes`, so volume data is never caught by
it. `prune` and `volume-rm` without `--yes` report what they would do, change
nothing, and exit 0.

## Commands

## Commands

- [`ed machines docker ps`](./ps.md)
- [`ed machines docker images`](./images.md)
- [`ed machines docker volumes`](./volumes.md)
- [`ed machines docker networks`](./networks.md)
- [`ed machines docker df`](./df.md)
- [`ed machines docker logs`](./logs.md)
- [`ed machines docker inspect`](./inspect.md)
- [`ed machines docker start`](./start.md)
- [`ed machines docker stop`](./stop.md)
- [`ed machines docker restart`](./restart.md)
- [`ed machines docker rm`](./rm.md)
- [`ed machines docker pause`](./pause.md)
- [`ed machines docker unpause`](./unpause.md)
- [`ed machines docker rmi`](./rmi.md)
- [`ed machines docker volume-rm`](./volume-rm.md)
- [`ed machines docker prune`](./prune.md)
- [`ed machines docker compose ls`](./compose-ls.md)
- [`ed machines docker compose up`](./compose-up.md)
- [`ed machines docker compose down`](./compose-down.md)
- [`ed machines docker compose restart`](./compose-restart.md)
- [`ed machines docker compose pull`](./compose-pull.md)
- [`ed machines docker compose logs`](./compose-logs.md)

## Exit codes

| Code | When |
| --- | --- |
| 0 | The command did what it said. A dry run of `prune` or `volume-rm` also exits 0, having changed nothing, and so do `--help` and `--version`. |
| 1 | Docker ran and refused, or failed: no such container, an image still in use, a volume still attached, a compose file compose could not find. The message names the verb and the machine, and docker's own stderr is the hint. Also a remote command that outran its timeout, and a `logs` stream whose `ssh` would not start. |
| 2 | `--tail` was negative, or the command line was wrong in the ordinary way: an unknown flag, a missing `<machine>` or `<container>`, a `--tail` that is not a number. |
| 3 | The machine name matched nothing or matched several; `<what>` was not one of the five prune targets; `<project>` was not in `compose ls`; `inspect` got a zero status and no output. |
| 4 | The machine could not be reached, docker on it is not usable (not installed, the daemon down, or this user cannot talk to the socket), or `ssh` itself could not be launched for a non-streaming command. |
| other | `logs` and `compose logs` propagate the remote process's own exit code verbatim, so anything docker returns reaches you unchanged. |

The docker availability failures all read the same way, with the specific reason
as the hint:

```
error: docker is not usable on Asus TUF 7
hint: docker is not installed there
```

The other hints on that message are `this user cannot talk to the docker
socket`, `The Docker daemon is not running.` and, when docker answered with
something unrecognisable, `docker reported an unknown state`.

## Notes and gotchas

- Word order is free. `ed machines tuf docker ps` and
  `ed machines docker ps tuf` are the same invocation: the machine is rewritten
  into the position the parser expects. A subcommand name always wins, so a
  machine literally called `docker` has to be named as
  `ed machines show docker`.
- `ed tuf docker ps` is not this page. Naming a machine as the first word makes
  the rest a raw remote command, so that line runs docker's own `ps` on the
  machine and prints docker's own table. Add `machines` to get the parsed form.
  This is the escape hatch for everything not covered here: `ed tuf docker
  buildx ls`, `ed tuf docker exec -it api sh`.
- `ed machines docker <machine>` with no verb is `ps`, and
  `ed machines docker compose <machine>` with no verb is `compose ls`.
- There is no `ed machines docker exec`. The Docker window's shell button is
  `ed machines exec --tty <machine> 'docker exec -it <container> sh'`, and
  `--tty` is what makes an interactive shell work at all.
- Every verb, including both dry runs, starts by running
  `docker version --format '{{json .}}'` on the machine with a 25 second ceiling
  and refusing to go on unless the daemon answered. That is the one round trip
  you pay for before anything else happens, and it is why an unreachable machine
  exits 4 even for a command that would have changed nothing.
- Docker commands always run in the SSH login directory. The remembered `cd`
  that `ed <machine> cd ...` sets belongs to `ed machines exec` and does not
  reach this page, which is why the compose verbs pass a project name rather
  than a directory.
- The timeouts are per command: 25 seconds for the version probe, 45 for `ps`,
  `images`, `volumes` and `df`, 30 for `networks`, `inspect` and `compose ls`,
  120 for every container lifecycle verb and for `rmi` and `volume-rm`, 300 for
  `prune` and for `compose up`, `down` and `restart`, 900 for `compose pull`.
  `logs` and `compose logs` have none. A command that outruns its ceiling has
  its `ssh` sent `SIGTERM`, then `SIGKILL` two seconds later, and surfaces as
  exit 1 while the work carries on unsupervised on the machine.
- `--json` output is one document per invocation, keys sorted, two space indent.
  Nothing on this page streams JSON, and nothing here takes `--json --follow`.
- Three verbs have no `--json` at all: `logs`, `inspect` and `compose logs`.
  `inspect` does not need one, since its output is already docker's JSON.
- The container id you pass is never resolved by `ed`. Names, short ids and full
  ids all go to docker as typed, so docker's own matching rules apply, including
  its refusal when a short id is ambiguous.
- `ps --json` drops two fields it collects. Network rx and tx bytes are parsed
  out of `docker stats` and never reach the document; only CPU and memory do.
- Volume sizes are never reported by `volumes`. Use `df`.
- Every mutating verb here is claimed by a Docker window action except the four
  compose lifecycle verbs, which the window does not have: it groups containers
  by compose project but never runs compose.
- Some hints embed the machine's display name unquoted, so a machine whose name
  has spaces produces a hint you cannot paste as is. Use the ssh alias, `tuf`,
  or any unambiguous prefix instead.
- These commands never need Edith to be running, and never ask macOS for a
  permission. Everything they touch is on the other machine.

## Where to go next

- [`ed machines`](../machines/README.md) for the machine directory itself, connecting
  and disconnecting, and `ed machines metrics` for the host the containers run
  on.
- [Running commands on a machine](../machines-remote/README.md) for the raw form,
  `--tty`, and everything docker can do that this page does not parse.
- [`ed machines files`](../machines-files/README.md) for the compose files and bind
  mounts behind these projects.
- [`ed machines power`](../machines-power/README.md) for the systemd unit that starts
  docker, and for the machine's own power state.
- [Conventions and contracts](../conventions.md) for the exit code table and the
  `--json` guarantees these commands follow.
- [The `ed` command line](../README.md) for the rest of the reference.
