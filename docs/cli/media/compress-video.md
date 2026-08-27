# `ed media compress-video`

Compresses one complete local video into an H.264 MP4 at or below a requested file-size
limit. The encoder derives a bitrate and a bounded resolution from the source duration,
frame rate and target size. If rate control overshoots, it retries with a smaller budget.

Usage:

```
ed media compress-video <input> --to <directory> [--target-mb <megabytes>] [--no-audio] [--json]
```

Options:

| Name | Values | Default | Meaning |
| --- | --- | --- | --- |
| `--to` | directory path | required | Folder that receives the MP4. |
| `--target-mb` | `1` through `512` | `20` | Hard output limit in decimal megabytes. |
| `--no-audio` | flag | off | Omit every source audio track. |
| `--json` | flag | off | Emit one structured result document. |

The command preserves the whole duration. It does not trim, crop, join or otherwise edit
the timeline. If the selected limit cannot carry a usable full-length video, the command
removes the incomplete output and exits 4.

The JSON object contains `operation`, `input`, `output`, `inputBytes`, `outputBytes`,
`targetBytes`, and `audio`. A successful result always has `outputBytes <= targetBytes`.

Examples:

```
ed media compress-video demo.mov --to ./exports
ed media compress-video recording.mp4 --to ./share --target-mb 8 --no-audio
ed media compress-video presentation.mov --to ./exports --target-mb 100 --json
```

[Back to `ed media`](./README.md) · [All `ed` commands](../README.md)
