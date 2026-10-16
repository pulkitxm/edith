# `ed studio run`

[Back to `ed studio`](./README.md)

Runs a Studio tool on files and prints the path of every result. Tools that
take one file at a time run on each file you pass; tools that combine files,
such as `pdf.merge`, use them in the order given. When one file of a batch
fails, the others still finish and the failure is reported on stderr.

Usage:

```
ed studio run <tool> <files...> [--set <key=value>...] [--output-dir <folder>] [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<tool>` | a tool id from `ed studio tools` | required | The tool to run. Editor tools such as `pdf.edit` only open in the app. |
| `<files...>` | paths | depends on the tool | The input files. Web tools take none and use `--set url=…`. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--set` | `key=value`, repeatable | tool defaults | One setting. Keys and allowed values come from `ed studio info`. Percentages accept `40%` or `0.4`, ranges accept `0:05-0:12`, and toggles accept `true` or `false`. |
| `--output-dir` | folder | next to each input | Save every result in this folder instead. |
| `--json` | flag | off | Emits `tool`, `outputs` (path, kind, bytes), `inputBytes`, `outputBytes`, `notes` and `failures`. |

Exit codes follow [the conventions](../conventions.md): 2 for a bad setting or a
file the tool cannot take, 3 for a missing file or tool, 4 when an engine such
as FFmpeg is missing.

Examples:

```
ed studio run pdf.merge intro.pdf body.pdf appendix.pdf
ed studio run pdf.compress scan.pdf --set level=extreme
ed studio run image.convert *.heic --set format=jpg --output-dir ~/Desktop/converted
ed studio run video.to-gif demo.mov --set range=0:02-0:06 --set width=480
ed studio run pdf.redact contract.pdf --set "terms=Jane Doe" --set phones=true
ed studio run pdf.scan receipt-1.jpg receipt-2.jpg --set look=mono
```

## Where to go next

- [`ed studio probe`](./probe.md)
- [All `ed` commands](../README.md)
