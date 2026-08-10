# `ed machines docker volume-rm`

Removes a volume and everything in it. Does nothing without `--yes`.

```
ed machines docker volume-rm [--json] [--yes] <machine> <volume>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to act on. |
| `<volume>` | volume name, exactly as `ed machines docker volumes` prints it | required | Which volume to remove. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the human lines. |
| `--yes` | flag | off | Actually remove it. Without this nothing is touched. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

Without `--yes` the command says what it would do and exits 0. The refusal note
goes to stderr, so a script reading stdout sees only the plan:

```
$ ed machines tuf docker volume-rm pg_data
would remove volume pg_data and everything in it
nothing was removed; pass --yes to go ahead
```

## `--json` shape

The same three keys in both directions. `removed` is the one that changes:

```json
{
  "machine": "Asus TUF 7",
  "removed": false,
  "volume": "pg_data"
}
```

With `--yes`, and after docker agreed:

```json
{
  "machine": "Asus TUF 7",
  "removed": true,
  "volume": "pg_data"
}
```

## Examples

```
ed machines tuf docker volume-rm pg_data
ed machines tuf docker volume-rm pg_data --json
ed machines tuf docker volume-rm pg_data --yes
```

## Behaviour notes

A volume is where a container keeps the data it means to survive a restart, so
this is the one container operation with nothing behind it: no trash, no undo,
no copy on the machine. `--yes` exists for that reason, and the dry run is the
default rather than an option.

With `--yes` the remote command is `docker volume rm <volume>`, under a 120
second ceiling. Docker refuses to remove a volume a container still refers to,
even a stopped one, and that refusal is exit 1 with docker's message as the
hint; remove or recreate the container first. There is no force flag here.

The dry run is not free: `ed` still opens the connection and checks that docker
is usable before it prints the plan, so `volume-rm` without `--yes` against an
unreachable machine exits 4 rather than 0.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
