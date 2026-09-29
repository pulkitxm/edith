# Audio and beats

## Choose the audio model deliberately

Separate source audio, clip-anchored additions and independent timeline audio.
Source gain or mute follows its clip. Anchored sound can be split, trimmed or
retimed with the video. Independent music and voiceover should retain their
intended output placement when shots are rearranged.

Read `ed studio edit schema` and help before constructing audio operations.
Discover whether independent audio, source offsets, fades, looping, detachment,
beat analysis and markers exist in this installation. Never guess their names.
If only anchored audio is supported, disclose that limitation for a request that
requires independent music rather than silently binding the song to a shot.

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

## Verify sound as sound

Project validation proves structural compatibility, not the finished mix.
Probe exported audio streams and duration, inspect peaks or loudness where tools
are available, and review audible cues and sync when listening is available.
A waveform or successful render alone does not prove dialogue clarity. In a
headless session without listening, label subjective listening checks pending.
Do not launch a player or move the mouse just to complete a check.
