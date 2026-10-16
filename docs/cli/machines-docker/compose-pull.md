# `ed machines docker compose pull`

Pulls the images a compose project uses.

```
ed machines docker compose pull [--json] <machine> <project>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to act on. |
| `<project>` | compose project name, exactly as `compose ls` prints it | required | Whose images to pull. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the one-line confirmation. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

## `--json` shape

```json
{
  "action": "pull",
  "machine": "Asus TUF 7",
  "project": "noveum-local-db"
}
```

## Examples

```
ed machines tuf docker compose pull noveum-local-db
ed machines tuf docker compose pull noveum-local-db --json
```

## Behaviour notes

Runs `docker compose -p <project> pull` with a 900 second ceiling, the longest
on this page, because pulling several images over a slow link is the one thing
here that legitimately takes a quarter of an hour. Progress is not streamed:
compose's output is collected and discarded on success, and only the
confirmation line is printed. Pass through `ed tuf 'cd /srv/app && docker
compose pull'` if you want to watch it.

Pulling needs the compose file, so this is the other verb, with `up`, that
depends on compose finding the project's configuration from the login directory.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
