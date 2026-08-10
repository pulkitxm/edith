# `ed machines unmount`

Unmounts a machine's file system again. Aliased `umount`.

```
ed machines unmount <machine> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the line. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines unmount tuf
unmounted /Users/pulkit/Edith/tuf
```

## `--json` shape

```json
{
  "machine": "Asus TUF 7",
  "mountPoint": "/Users/pulkit/Edith/tuf",
  "readOnly": false,
  "remotePath": "/",
  "source": "tuf:/"
}
```

## Examples

```
ed machines unmount tuf
ed machines umount tuf --json
```

## Behaviour notes

The document describes the mount that was released, so it is the same shape
`mount` printed when it went up.

`umount` is tried first and `diskutil unmount force` second, which is what gets
a mount down when a shell is still sitting in it. The mount point is then
removed if it is empty and inside `~/Edith`, so the folders do not pile up; a
mount point you chose with `--at` is left where it is.

A machine that is not mounted exits 4 rather than pretending to have done
something:

```
$ ed machines unmount tuf
error: Asus TUF 7 is not mounted.
```

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
