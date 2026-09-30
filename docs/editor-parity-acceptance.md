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
