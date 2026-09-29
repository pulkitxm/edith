# `ed studio edit review-report`

[Back to `ed studio`](./README.md) · [CLI reference](../README.md)

Review a local `.openscreen` project without opening the app or changing its media.
The report measures the native composition, not an encoded master.

## Usage

```sh
ed studio edit review-report demo.openscreen --expect-duration 12 --expect-frame-count 720 --expect-shot-count 4 --json
ed studio edit review-report demo.openscreen --check-borders --max-border-frames 10000 --output review.json --json
```

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `PROJECT` | required | Local native `.openscreen` project. |
| `--expect-duration` | unset | Expected composition duration in seconds. |
| `--duration-tolerance` | `0.001` | Allowed absolute duration difference in seconds. |
| `--expect-frame-count` | unset | Expected output frame count, compared exactly. |
| `--expect-shot-count` | unset | Expected surviving clip count, compared exactly; speed slices are not extra shots. |
| `--check-borders` | off | Assess source coverage using native crop, affine transforms and cursor-driven zoom. |
| `--max-border-frames` | `10000` | Maximum checked output frames, from 2 to 100000. |
| `--output` | unset | Save the complete report to a `.json` file and return its path, status and SHA-256 checksum. |
| `--overwrite` | off | Atomically replace an existing report. |
| `--json` | off | Use structured runtime errors; completed reports are always JSON. |

## Report and coverage

The versioned report includes actual duration, frame count, shot count, rational
frame duration, and per-clip and per-segment half-open source/output ranges. Source
frame coordinates use nominal FPS and are explicitly not decoded VFR sample indices.
Stills have no source frame indices. Output frame intervals use presentation times.
Nearest saved marker deltas at each boundary are marker minus boundary in seconds
and project-output frames.

Missing or unreadable dependencies produce diagnostics. If composition construction
fails, actual duration and counts are unavailable, and requested comparisons are
`not_assessed`. An expectation never replaces the actual measurement.

Border checks inverse-transform corners into the cropped, oriented source extent;
they do not inspect black pixels. Intentional fit margins, padding, rounded corners,
shadow and background settings have separate flags. Unknown webcam composition is
`not_assessed`. Longer timelines have explicit `sampled` coverage, checked frame
numbers, and a flag indicating whether mandatory clip endpoints, transform
keyframes, zoom boundaries and cursor changes fit within the bound.

## Output and exit status

`passed` exits 0. Completed failed, sampled or unavailable requested assessments exit
1 with the report on stdout and empty stderr, so MCP retains the diagnostic report.
Invalid arguments and I/O failures use the usual structured error path with `--json`.
Stdout JSON is capped at 4 MiB; `--output` supports a complete report up to 32 MiB.
Project files, original media, sidecars and other dependencies are protected output
destinations, including filesystem aliases.

MCP exposes `edith_studio_edit_review_report` with the same CLI argument array.
