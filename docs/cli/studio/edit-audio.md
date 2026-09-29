# `ed studio edit audio`

[Back to `ed studio`](./README.md) · [All CLI commands](../README.md)

Analyze a native project audio or video asset without opening the app. The default
subcommand is `analyze`. Audio-track offsets and loops are not inferred.

## `ed studio edit audio analyze`

Measures waveform energy and transients using native audio decoding. Tempo is an
optional interval-consistency estimate, not a confirmed musical beat grid.

```sh
ed studio edit audio analyze demo.openscreen --asset ASSET_ID --json
ed studio edit audio analyze demo.openscreen --asset ASSET_ID \
  --source-in 1 --source-out 3 --output-start 10 --playback-rate 2 \
  --fps 60000/1001 --json > analysis.json
jq '.markerDocument' analysis.json > markers.json
ed studio edit markers import demo.openscreen --input markers.json --json
```

| Option | Meaning and default |
| --- | --- |
| `--asset ID` | Required project audio or video asset ID. Still images are rejected. Processed audio takes precedence over the original URL. |
| `--sensitivity N` | Transient sensitivity from 0 to 1; default 0.5. |
| `--refractory-seconds N` | Refractory duration in seconds; default 0.08. |
| `--minimum-spacing-seconds N` | Minimum transient spacing in seconds; default 0.15. |
| `--maximum-waveform-bins N` | Even limit from 2 to 2048; default 2048. |
| `--maximum-transients N` | Limit from 1 to 10000; default 10000. |
| `--source-in N` | Inclusive source-range start in seconds. |
| `--source-out N` | Exclusive source-range end in seconds, within decoded audio. |
| `--output-start N` | Nonnegative output start in seconds. |
| `--playback-rate N` | Source-to-output rate from 0.05 to 20. |
| `--fps N/D` | Explicit rational output FPS; an integer is also accepted. |
| `--project-fps` | Validated saved project FPS, otherwise native composition FPS. |
| `--json` | Structured runtime errors; successful results are always JSON. |

Supply all four mapping options and exactly one FPS choice together, or omit mapping
and FPS entirely. Mapping uses
`outputStartSeconds + (sourceSeconds - sourceInSeconds) / playbackRate`.
Empty projects without saved FPS require explicit `--fps`.

The version 1 report contains `assetID`, `sourcePath`, `durationSeconds`,
`samplePositionUnit: "source_samples"`, `sampleRateUnit: "Hz"`, and `analysis`.
Analysis includes `sampleRate`, `sampleCount`, waveform bins (`startSample`,
`sampleCount`, `peak`, `meanSquare`), transients (`sample`, `strength`),
`transientsTruncated`, and optional `tempoEstimate`. With mapping requested, it also
returns `mapping`, `frameRate`, and an importable version 1 `markerDocument`.

Analysis is read-only. Runtime failures return `{version, error: {code, message}}`
on stderr with `--json`. MCP tool `edith_studio_edit_audio_analyze` accepts the same
CLI arguments in its `arguments` array, with a 300-second deadline and 4 MiB output
limit.

See [output-frame markers](./edit-markers.md) for editing and interchange.
