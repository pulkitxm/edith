# `ed machines docker compose ls`

Lists the compose projects on the machine. Also answers to `list`, and runs when
you name no compose subcommand.

```
ed machines docker compose ls [--json] <machine>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to ask. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the plain lines. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

Human output is one project name per line. With no projects, the message goes to
stderr and stdout stays empty:

```
$ ed machines tuf docker compose ls
no compose projects on Asus TUF 7
```

## `--json` shape

A top-level array of strings, and `[]` rather than nothing when there are none:

```json
[
  "noveum-local-db"
]
```

Only the project name is reported. The status and config file path that
`docker compose ls` also prints are parsed away.

## Examples

```
ed machines tuf docker compose ls
ed machines tuf docker compose list --json
ed machines tuf docker compose ls --json | jq -r '.[]'
```

## Behaviour notes

Read only, 30 second ceiling, `docker compose ls --format json 2>/dev/null`.
Note the missing `-a`: docker lists only projects that are currently running, so
a project whose containers are all stopped does not appear here even though its
containers still exist. That is not cosmetic, because every other compose verb
refuses a project this command did not list.

To see the stopped ones, ask docker directly through the raw form:

```
$ ed tuf 'docker compose ls -a --format json'
[{"Name":"noveum-local-db","Status":"exited(3)","ConfigFiles":"/home/pulkit/Desktop/noveum-app-nextjs/extras/db/docker-compose.local-db.yml"}]
```

A machine whose docker has no compose plugin fails rather than reporting
nothing. Compose's complaint is discarded by the `2>/dev/null`, but its non-zero
status is not, so you get exit 1 naming the command that failed and an empty
hint:

```
$ ed machines old-box docker compose ls
error: docker compose ls --format json 2>/dev/null exited 1 on old-box
hint:
```

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
