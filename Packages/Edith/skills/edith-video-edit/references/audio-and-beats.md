# Audio and beats

## Choose the audio model deliberately

Separate source audio, clip-anchored additions and independent timeline audio.
Source gain or mute follows its clip. Anchored sound can be split, trimmed or
retimed with the video. Independent music and voiceover should retain their
intended output placement when shots are rearranged.

Read `ed studio edit schema` and help before constructing audio operations.
`addAudio` imports independent music or voiceover: `start` uses rendered output
seconds and `offset` uses original audio-source seconds. Import video or stills
first so the intended output start lies inside the rendered timeline. The imported
track is clipped to that timeline's end. Video rearrangement does not bind it to
a shot; recheck its intended end after shortening the cut.

An approved audio reference may be inside a video container. Import it with
`addAudio` as an audio asset only, not `addMedia` as a flattened visual replacement.
Preserve the original music reference and editable visual sources when required.
For unchanged AAC delivery, the selected source must already satisfy full-stream
copy constraints; mastering to PCM and AAC packet copy are separate workflows.

Use `moveAudio`, `splitAudio`, `trimAudio`, `audioFades`, `audioOptions` and
`removeAudio` for independent tracks. Read their required fields and bounds from
the schema. `detachAudio` snapshots a clip's audio placement, source offsets,
speed slices and envelopes, then mutes its source. It requires source audio and
can detach a clip only once. Check the resulting mix instead of adding a duplicate.

`addAudio.name` and `detachAudio.name` define plan-local group aliases. Follow
`audioAliases` and `audioIDs` in the apply result: split/trim can change a group's
members, and removal can leave an empty array. Later plans use persisted track
IDs from `show`, not an alias from an earlier apply or an ID from a dry-run.

For a project with at least four rendered seconds and a synthetic audio file
longer than four seconds, this public plan creates a quiet independent bed:

```json
{
  "version": 1,
  "operations": [
    {"addAudio": {"path": "synthetic-tone.wav", "start": 0, "offset": 0, "name": "bed"}},
    {"trimAudio": {"trackID": "bed", "start": 0, "end": 4}},
    {"audioFades": {"trackID": "bed", "fadeIn": 0.2, "fadeOut": 0.3}},
    {"audioOptions": {"trackID": "bed", "gainDb": -6, "muted": false, "loop": false}}
  ]
}
```

The example's gain is a creative mix choice, not loudness normalization. For a
specified loudness target, measure first and use the delivery skill's mastering
guidance. Preserve approved-source provenance and remeasure the encoded output.

Establish source range, output start, gain, mute, fades and looping intentionally.
When detaching recorded audio, check whether the original clip remains audible
to avoid doubling it. A loop changes the audible phrase at the seam; inspect it.
After changing the cut, verify dialogue remains intelligible and music does not
cover a required cue or extend beyond the intended end.

## Align cuts to meaningful beats

Use a discovered beat-analysis API where available. Inspect the detected grid,
confidence and requested musical accents before treating every beat as a cut.
If analysis is unavailable, use supplied cue times or report the missing support.
Do not fabricate detected beat positions from a guessed tempo.

Convert music-source beat times to output time using the track's source offset,
output placement and any supported retiming. For unretimed music:
`outputBeat = outputStart + sourceBeat - sourceOffset`.
Discard beats outside the audible source range, and handle loop repetitions using
the actual loop duration. Quantize each selected beat to the output frame grid
using a declared rounding rule. Record the quantization error.

For example, at `30000/1001` fps, a cue at exactly 1 second is nearest to frame
30, which starts at 1.001 seconds. Record the 0.001-second difference rather than
claiming exact equality. A command that floors review times might select frame
29 for `--time 1`; request the chosen frame's start time when reviewing frame 30.

Use native markers when the schema advertises them. Otherwise keep cue labels
and intended frames in the ledger; a ledger entry is not a saved native marker.
Arrange cuts at selected accents, preserving minimum legal clip durations and
the required story. Recalculate downstream positions after each speed or trim
change instead of repeatedly nudging rounded seconds.

For waveform review, `contact-sheet` supports `--waveform-asset` with explicit
`--source-in`, `--source-out`, `--output-start` and `--playback-rate`. These map
source audio into output time; choosing a track does not infer offsets or loops.
`--show-beat-markers` draws saved markers. Newly detected transients are not saved
confirmed beats, and source linear waveform peaks do not measure the final mix.

## Verify sound as sound

Project validation proves structural compatibility, not the finished mix.
Probe exported audio streams and duration, inspect peaks or loudness where tools
are available, and review audible cues and sync when listening is available.
A waveform or successful render alone does not prove dialogue clarity. In a
headless session without listening, label subjective listening checks pending.
Do not launch a player or move the mouse just to complete a check.
