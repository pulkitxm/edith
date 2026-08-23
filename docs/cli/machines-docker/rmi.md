# `ed machines docker rmi`

Removes an image. Also answers to `remove-image`.

```
ed machines docker rmi [--json] [--force] [--yes] <machine> <image>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to act on. |
| `<image>` | image name, `repository:tag`, or an id from `ed machines docker images` | required | Which image to remove. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the one-line confirmation. |
| `--force` | flag | off | Remove it even when a container still refers to it. Adds `-f` to the docker command. |
| `--yes` | flag | off | Apply the removal. Without it, print the exact plan. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

Human output is one line, `removed image <image>`.

## `--json` shape

```json
{
  "action": "remove docker image",
  "applied": false,
  "changed": false,
  "forced": false,
  "image": "postgres:16",
  "machine": "Asus TUF 7",
  "targets": [
    "Asus TUF 7:image:postgres:16"
  ]
}
```

`forced` records whether you passed `--force`, not whether force was needed.
`image` is echoed back as you typed it.

## Examples

```
ed machines tuf docker rmi postgres:16
ed machines tuf docker rmi de3a4eab8fdf --force --yes
ed machines tuf docker remove-image postgres:16 --json
```

## Behaviour notes

Runs `docker image rm [-f] <image>` under a 120 second ceiling after `--yes`.
Without confirmation it reports the resolved machine and image, changes
nothing, and does not connect.

Without `--force`, docker refuses to remove an image a container still refers
to, even a stopped one, and that refusal becomes exit 1 with docker's message as
the hint. With `--force` docker untags it and removes it when nothing else holds
the layers. Removing an image that several tags point at removes only the tag
you named unless you pass an id.

This is the Docker window's image delete button, which always runs the
unforced form.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
