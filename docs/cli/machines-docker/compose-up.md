# `ed machines docker compose up`

Brings a compose project up in the background.

```
ed machines docker compose up [--json] <machine> <project>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to act on. |
| `<project>` | compose project name, exactly as `compose ls` prints it | required | Which project to bring up. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the one-line confirmation. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

Human output is one line, `up -d <project>`.

## `--json` shape

```json
{
  "action": "up -d",
  "machine": "Asus TUF 7",
  "project": "noveum-local-db"
}
```

`action` carries the compose action as it was sent, so it reads `up -d` rather
than `up`.

## Examples

```
ed machines tuf docker compose up noveum-local-db
ed machines tuf docker compose up noveum-local-db --json
```

## Behaviour notes

The project name is checked against `compose ls` before anything runs, and an
unknown one exits 3 with the projects that do exist as the hint, or with a nudge
to look again when there are none:

```
$ ed machines tuf docker compose up noveum-local-db
error: no compose project named noveum-local-db on Asus TUF 7
hint: run `ed machines Asus TUF 7 docker compose ls` to look again
```

That is the common failure, and it is usually not a typo: `compose ls` lists
only running projects, so a project that is fully down cannot be named here.
Bring it up through the raw form, from the directory that holds its file:
`ed tuf 'cd /srv/app && docker compose up -d'`.

The remote command is `docker compose -p <project> up -d`, run from the SSH
login directory, with no `-f` and no `--project-directory`. Compose has to be
able to find the project's configuration from there; when it cannot, its own
message comes back as the hint on an exit 1. The ceiling is 300 seconds.

There is no Docker window equivalent for this verb. The window groups containers
by compose project but never runs compose itself.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
