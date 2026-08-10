# `ed machines docker prune`

Reclaims space by removing unused docker objects. Does nothing without `--yes`.

```
ed machines docker prune [--json] [--yes] <machine> [<what>]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to act on. |
| `<what>` | `images`, `volumes`, `networks`, `builder` or `system` | `system` | Which family of unused objects to remove. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the human lines. |
| `--yes` | flag | off | Actually prune. Without it nothing is removed. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

Each target maps to exactly one docker command, and the dry run prints it:

| `<what>` | Command | What goes |
| --- | --- | --- |
| `images` | `docker image prune -af` | Every image no container uses, not just the dangling ones. |
| `volumes` | `docker volume prune -f` | Every volume no container uses, and the data in it. |
| `networks` | `docker network prune -f` | Every user-defined network nothing is attached to. |
| `builder` | `docker builder prune -af` | The whole build cache. |
| `system` | `docker system prune -f` | Stopped containers, unused networks, dangling images and build cache. Volumes are not included. |

```
$ ed machines tuf docker prune
would run: docker system prune -f
pass --yes to do it
```

## `--json` shape

The two shapes differ, which is worth knowing before you parse them. The dry run
reports the command it would have run:

```json
{
  "applied": false,
  "command": "docker image prune -af",
  "machine": "Asus TUF 7",
  "target": "images"
}
```

The applied run reports what docker said instead:

```json
{
  "applied": true,
  "machine": "Asus TUF 7",
  "output": "Total reclaimed space: 3.585GB",
  "target": "images"
}
```

`command` is present only when `applied` is false, and `output` only when it is
true. `output` is docker's stdout with leading and trailing whitespace trimmed,
which for a real prune is a list of deleted ids followed by the reclaimed total.
Without `--json` that same stdout is printed raw.

## Examples

```
ed machines tuf docker prune
ed machines tuf docker prune images --json
ed machines tuf docker prune builder --yes
ed machines tuf docker prune volumes --yes
```

## Behaviour notes

The target is checked before anything else happens, including before the
connection is opened, so a typo costs nothing and exits 3 with the valid list:

```
$ ed machines tuf docker prune everything
error: docker cannot prune everything
hint: try: images, volumes, networks, builder, system
```

`volumes` is spelled out as its own target rather than folded into `system` on
purpose. `docker system prune` does not touch volumes unless it is asked to, and
`ed` never asks it to, so the only way to lose volume data here is to type
`prune volumes --yes`.

`prune images` is more aggressive than `docker image prune` typed by hand. The
`-a` means every image without a container, not only the untagged ones, so a
tagged image you pulled for later goes too. Check
`ed machines docker df --json` first: the `Images` row's `reclaimableBytes` is
what this will free.

With `--yes` the ceiling is 300 seconds, longer than any container verb here and
second only to `compose pull`. A prune that outruns it is reported as a failure
while docker keeps going on the machine.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
