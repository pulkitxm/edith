# `ed media convert-images`

Converts one or more local images into a shared output folder. Every image is processed
independently, so one unreadable input does not discard successful results from the same
batch.

Usage:

```
ed media convert-images <inputs>... --to <directory> [--format <format>] [--quality <value>] [--max-dimension <pixels>] [--json]
```

Options:

| Name | Values | Default | Meaning |
| --- | --- | --- | --- |
| `--to` | directory path | required | Folder that receives every converted file. |
| `--format` | `jpeg`, `png`, `heic` | `jpeg` | Output image format. |
| `--quality` | `0.1` through `1` | `0.82` | Lossy compression quality for JPEG and HEIC. |
| `--max-dimension` | `0` through `20000` | `1600` | Largest pixel edge. `0` keeps the source dimensions. |
| `--json` | flag | off | Emit one structured result document. |

Resizing preserves aspect ratio and never enlarges an image. Orientation metadata is
applied to the pixels during conversion. Metadata is not copied into the new file.

The JSON object contains `operation`, `outputDirectory`, `succeeded`, `failed`, and
`results`. Each result contains `input`, nullable `output`, `inputBytes`, `outputBytes`,
and nullable `error`.

Examples:

```
ed media convert-images photo.png --to ./converted
ed media convert-images *.tiff --to ./web --format heic --quality 0.75
ed media convert-images a.jpg b.jpg --to ./thumbs --format png --max-dimension 512 --json
```

[Back to `ed media`](./README.md) · [All `ed` commands](../README.md)
