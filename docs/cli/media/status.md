# `ed media status`

Shows whether the Media Toolkit extension is enabled and reports the saved defaults used
by its image and video workspaces. Running bare `ed media` invokes the same command.

Usage:

```
ed media [status] [--json]
```

The human-readable result lists the current image format, maximum image dimension,
quality, target video size, and audio preference. The JSON object contains `enabled`, an
`image` object with `format`, `formats`, `maxDimension`, and `quality`, plus a `video`
object with `keepAudio` and `targetMegabytes`.

Examples:

```
ed media
ed media status
ed media --json
```

[Back to `ed media`](./README.md) · [All `ed` commands](../README.md)
