# `ed media`

`ed media` processes images and videos entirely on this Mac. It does not upload files,
start a background service, or require a third-party executable. Image conversion uses
ImageIO, and video compression uses AVFoundation.

The image command accepts a batch and writes collision-safe files into one output folder.
The video command writes a complete H.264 MP4 whose final byte count is at or below the
requested limit. Both commands preserve their inputs and can run while Edith is closed.

## Commands

- [`ed media convert-images`](./convert-images.md)
- [`ed media compress-video`](./compress-video.md)

## Common behavior

- Relative paths resolve from the current directory, and paths beginning with `~` expand
  to the current home directory.
- Output folders are created when they do not exist.
- Existing files are never overwritten. Outputs use `-converted`, then a numeric suffix
  when necessary.
- JPEG, PNG and HEIC are the image output formats. ImageIO accepts any input format that
  macOS can decode.
- Video output is H.264 in an MP4 container. Audio is AAC unless `--no-audio` is passed.
- Decimal megabytes are used for video limits, so `20 MB` means `20,000,000` bytes.
- `--json` prints exactly one JSON document on stdout. Diagnostics remain on stderr.
- Pressing Control-C cancels processing. A staged image or incomplete video is removed.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Processing completed. Image batches may include individual failures in the result. |
| 1 | A file encoder, output directory or other operating system operation failed. |
| 2 | An option was out of range or a required argument was missing. |
| 3 | An input path did not exist. |
| 4 | The source format was unsupported, the target was impossible, or processing was cancelled. |

## Related commands

- `ed extensions enable mediaToolkit`
- `ed config ls --group media --json`
- `ed extensions status mediaToolkit --json`

[All `ed` commands](../README.md)
