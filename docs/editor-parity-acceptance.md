# Editor parity acceptance

The parity fixture is an isolated synthetic project specification: 47 distinct
original assets, five videos and 42 photos, 47 captions, and 5,588 frames at 60 fps.
The delivery canvas is 2,160 by 3,840. Audio starts at zero and covers exactly
4,470,400 samples at 48 kHz. The requested master is -16 LUFS, at most -1.5 dBTP,
an 11 LU loudness-range target, and a final 0.25-second fade.

Generate fixtures with the existing Python and FFmpeg installations:

```sh
python3 scripts/editor_parity_fixtures.py generate /absolute/new/synthetic-fixture
python3 scripts/editor_parity_fixtures.py verify /absolute/new/synthetic-fixture
```

Generation accepts no media inputs. All originals are color charts,
checkerboards, or synthesized tones. The fixture includes six small canonical
baseline exports. Their hashes and every original asset hash are protected.
They are generated once, then verified before and after acceptance operations.
No real projects, exports, screenshots, or recordings belong in this fixture.

The manifest records half-open frame intervals with independently generated
durations between 43 and 442 frames, totaling exactly 5,588. Each video has two
extra source frames, allowing the public trim operation to set its exact shot
duration. Photos stay as original PNG assets. Eighteen photos use contained
framing with a blurred original background, and 24 use fill framing. One
contained photo has a custom foreground source crop, and two fill photos use
off-center focal points. Captions contain independent synthetic text: 43 have
one line, four have two lines, 45 use size 104, and two use size 112.
Video frames and photos have colored edge
strips, a unique flat center patch, and surrounding checkerboard detail for
independent framing, blur, color, and source-identity checks.

Version 2 fixtures have different left and right soundtrack waveforms. Each
video frame also contains a nine-bit source-frame signature, rather than a
repeated still. Acceptance decodes 30 picture samples across the five videos:
start, middle, end, and adjacent frames. Correct timestamps cannot conceal a
frozen picture or a repeated sampled source frame.

## Integration contracts

The acceptance runner must discover public edit capabilities and operation
schemas from the integrated development binary before applying any plans.
New operation names and field structures must come from the implementing
workers. An unavailable capability is a failure, never a successful skip.

The integration needs these published contracts:

- Contain framing with a full-width centered original image and a blurred
  fill-cropped background derived from that same original. Blur radius,
  intensity, and color operation units must be explicit.
- FFmpeg-compatible brightness, contrast, and saturation semantics, or
  documented conversion rules that permit independent reference rendering.
- Caption creation, exact frame anchors, and round-trippable styling including
  font, size, bounds, alignment, foreground, background, outline, and shadow.
- A continuous output-clock audio track, end time, final fade, loudness
  normalization, measured loudness output, and an independent AAC compressed
  packet-copy path with its compatibility requirements.
- Native project registration and listing plus a headless open-request
  acknowledgement. The acceptance run must never launch a GUI.

Quick acceptance retains all 47 originals and exact 5,588-frame timing while
using a smaller render canvas. It is a fail-fast preflight, not full delivery
acceptance. Full acceptance must render the integrated 2,160 by 3,840 project
once and independently measure the final output before publishing a result.
An acceptance result is written atomically only after every required group
passes. Fixture verification alone is not product acceptance.

## Independent checker controls

```sh
python3 scripts/test-editor-parity-checks.py \
  --fixture /absolute/synthetic-fixture \
  --workspace /absolute/new/checker-controls
```

These controls exercise the verification code with independently generated
positive and negative examples. They do not run Edith and cannot establish
product acceptance. The output is named `checker-controls.json`, explicitly
sets `productAcceptance` to false, and never writes a full acceptance result.

`editor_parity_cli.py` supplies the common public-plan construction, schema
discovery, stdin and media-directory handling, revision guards, transaction
rollback checks, and atomic result publication. `editor_parity_checks.py`
checks exact project originals, caption frame anchors, decoded video frame
timestamps, audio waveform continuity, the final fade, independent FFmpeg
loudness, and AAC compressed packet identity.

Audio checks retain both original stereo channels. Each channel is checked in
contiguous 10-millisecond windows covering every sample, plus windows around
all 47 shot boundaries. Comparison uses an independently generated master and
its AAC encoding to calibrate per-window waveform and level tolerances. A
common overall gain is allowed; interior gaps, wrong channels, channel gain
changes, and incorrect fades are rejected. The reference carries the intended
mastering dynamics and fade. Controls include an interior dropout in the long
second shot and silent or duplicated right channels, all compensated back to
approximately -16 LUFS so aggregate loudness cannot mask their defects.

`editor_parity_pixels.py` produces reference pixels with FFmpeg, independently
of the native renderer. It checks contain geometry, full-width centering,
original-image blur, foreground-only crop, focal fill, FFmpeg EQ, and visible
caption bounds and contrast. Pixel tolerances are computed from an independent
H.264 positive control and incorrect render controls. The threshold is their
error midpoint, and controls must be separated by at least a factor of three.
Reports retain both measured control errors and the computed threshold.
Caption checks measure visible geometry and contrast, not font glyph equality.

The integrated runner still needs the finalized caption, background, mastering,
packet-copy, and lifecycle contracts before it can execute all ten required
groups. The shared result publisher rejects an incomplete group set. Quick
results use `quick-result.json`; only a complete full-resolution run may write
`result.json`. Both explicitly distinguish synthetic acceptance from real
project parity.

Publication uses an exclusively created unique temporary regular file and an
atomic no-clobber hard link. Existing files, dangling symlinks, and concurrently
created results are preserved. Run these filesystem controls separately:

```sh
python3 scripts/test-editor-parity-publication.py
```
