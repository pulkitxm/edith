# `ed machines docker compose down`

Takes a compose project down.

```
ed machines docker compose down [--json] <machine> <project>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to act on. |
| `<project>` | compose project name, exactly as `compose ls` prints it | required | Which project to take down. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the one-line confirmation. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

## `--json` shape

```json
{
  "action": "down",
  "machine": "Asus TUF 7",
  "project": "noveum-local-db"
}
```

## Examples

```
ed machines tuf docker compose down noveum-local-db
ed machines tuf docker compose down noveum-local-db --json
```

## Behaviour notes

The remote command is `docker compose -p <project> down`, with a 300 second
ceiling and the same project check `up` performs. `down` removes the project's
containers and its default network. Named volumes survive: `-v` is never passed,
and there is no flag here that would pass it. To remove a project's data as
well, list its volumes with `ed machines docker volumes` and take them with
`ed machines docker volume-rm --yes`.

After a successful `down` the project disappears from `compose ls`, so the
matching `up` through `ed` will not find it. That round trip is the reason to
prefer the raw form for projects you take all the way down.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
