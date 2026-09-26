# `ed studio probe`

[Back to `ed studio`](./README.md)

Describes a file the way Studio's file cards do: its kind and size, then pages
for a PDF, pixels and frames for an image, or duration, size and codecs for
video and audio. The JSON form also lists every tool that accepts the file.

Usage:

```
ed studio probe <file> [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<file>` | path | required | The file to describe. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document, including `tools`. |

Example:

```
ed studio probe clip.mov --json
```

## Where to go next

- [`ed studio run`](./run.md)
- [All `ed` commands](../README.md)
