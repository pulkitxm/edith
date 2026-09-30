# Soundtrack measurement and mastering

`ed studio edit audio health --json` reports whether Studio's detected FFmpeg
provides `loudnorm`, including the executable and engine version. FFmpeg is an
explicit dependency; these commands do not install it. Measurement uses the
EBU R128 loudnorm backend rather than a sample-peak gain estimate.

```sh
ed studio edit audio measure demo.openscreen --asset AUDIO_TRACK_ID --json
ed studio edit audio master demo.openscreen --track AUDIO_TRACK_ID \
  --duration 93 --output ./mastered-soundtrack --json
ed studio edit validate ./mastered-soundtrack/project.openscreen --json
ed studio edit render ./mastered-soundtrack/project.openscreen \
  --output ./delivery.mp4 --json
```

`measure` follows the selected asset's processed audio reference, if present.
It returns integrated LUFS, loudness range in LU, and true peak in dBTP with a
source SHA-256. Digital silence has `silent: true` and absent integrated/peak
fields. Very quiet gated-out audio can have an absent integrated value without
being digital silence. Neither can be mastered to a claimed integrated target.

`master` reads the selected independent soundtrack's **original** source from
sample zero. It never joins, repeats, or loops that source. The duration must
fit the video timeline, be at least 0.4 seconds, and align to a 48 kHz sample.
It resamples to stereo 48 kHz, trims to the exact sample count, applies a final
0.25-second linear fade, then runs measured two-pass loudnorm targeting
-16 LUFS, -1.5 dBTP, and LRA 11. The first measurement describes this prepared
source, including trim and fade. The rendered 24-bit PCM WAV is independently
remeasured before publication. Verification requires integrated loudness within
0.3 LU, peak no higher than -1.4 dBTP, and LRA no higher than 11.5 LU.

The new directory is published as one bundle only after verification:

- `soundtrack.wav`: read-only derived media, with exact PCM sample count.
- `report.json`: read-only source/artifact hashes, engine version, recipe,
  tolerances, and before/after measurements.
- `project.openscreen`: editable project copy with a fresh project identity.
  The selected track references a newly registered derived asset containing the
  same provenance. Its output starts at zero, source offset is zero, gain is
  unity, and timeline loops/fades are disabled because processing is baked in.
  Other tracks retain their settings. The original asset remains registered and
  the derived asset retains its original path for re-editing.

Existing directories are always refused, including on rerun. The original
project and media are never overwritten. Short sources, missing engines,
processing failures, cancellation, and failed verification publish no bundle.
Changing the derived track gain or mixing other tracks can change final export
loudness; the measurement claim applies to the registered soundtrack artifact.

MCP tools have identical CLI argument and JSON semantics:
`edith_studio_edit_audio_health`, `edith_studio_edit_audio_measure`, and
`edith_studio_edit_audio_master`. Measurement and mastering receive the same
six-hour timeout as delivery.
