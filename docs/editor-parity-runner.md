# Complete synthetic editor parity runner

The runner uses only generated fixtures and the explicitly supplied development
CLI. It must finish all required groups before publishing full acceptance.

The runner requires macOS and an available Swift compiler (`swiftc` on `PATH`,
provided by Xcode or the Command Line Tools). Native delivery appearance checks
compile a helper at runtime that uses AVFoundation and Core Image to normalize
decoded frames to sRGB. Confirm compiler availability with `swiftc --version`
before starting a run.

## Version 4 fixtures

```sh
python3 scripts/editor_parity_fixtures.py generate /absolute/new/parity-v4
python3 scripts/test-editor-parity-motion.py \
  --fixture /absolute/parity-v4 --workspace /absolute/new/motion-controls
```

Version 4 retains 47 originals, 42 photos, five videos, 47 captions, and 5,588
frames at 60 fps. Every video has an independently chosen nonzero source trim,
with enough original frames before and after the selected range. Its visible
frame signatures prove the exact source position, not just output timestamps.

Eighteen contained photos remain static. Twenty-three fill photos zoom linearly
from 1 to 1.025 and one from 1 to 1.012. The focal fill region is selected first,
then zoomed about that selected crop's center. This preserves both off-center
focal selections without anchoring motion to the uncropped original center.
The final visible frame reaches the full target zoom. Samples use fraction
`frame / (frames - 1)`; the endpoint keyframe is at `(frames - 1) / 60` seconds.
No replacement image is generated for
the project. Reference rasters are independent FFmpeg verification artifacts.

Photo originals use an aperiodic checker pattern so a wrong focal offset cannot
alias onto a visually identical repeating tile pattern. Independent motion
controls compare first, middle, and final pictures with measured codec noise,
and must reject a frozen-photo control. The source-trim controls also reject
an untrimmed original for each of the five videos.

## Integration requirements

- Discover operation schemas, including explicit `ffmpeg709` grading and
  styled output captions, from the binary being tested.
- Keep one runtime environment for every CLI call and the matching development
  app. Full open acceptance requires a real mounted-editor acknowledgement.
- Verify exact native styles and independent font glyphs, final mastered stereo
  audio, separate compressed AAC packet identity, and every source checksum.
- Run quick acceptance first. Render the full 2,160 by 3,840, 5,588-frame export
  once after all fail-fast groups pass.
- The exact soundtrack endpoint remains mandatory. No clock tolerance hides a
  missing source or output sample.

Checker-control reports are not product acceptance. No full result may be
published while an API, matching app, or required comparison is unavailable.

## Native visual preflight

```sh
python3 scripts/test-editor-parity-runner.py \
  --ed /absolute/development/ed --fixture /absolute/parity-v4 \
  --workspace /absolute/new/visual-preflight --visual-only
```

This scope executes five transaction checks, exact original trim and soundtrack
timing, 126 photo review frames, 30 video signature frames, 18 graded contained
photo references, a wrong-grading-mode negative control, and native register,
library, and unregister commands. It records `visual-preflight.json` with
`productAcceptance: false` and explicit pending groups. Registration paths are
compared after filesystem resolution because macOS may report `/var` for a
project Python resolves through `/private/var`.

## Complete quick and full runs

```sh
python3 scripts/test-editor-parity-runner.py \
  --ed /absolute/Edith.app/Contents/MacOS/ed --fixture /absolute/parity-v4 \
  --workspace /absolute/new/quick --mode quick
python3 scripts/test-editor-parity-runner.py \
  --ed /absolute/Edith.app/Contents/MacOS/ed --fixture /absolute/parity-v4 \
  --workspace /absolute/new/full --mode full \
  --quick-result /absolute/quick/quick-result.json \
  --runtime-env /absolute/quick/runtime-environment.json
```

Before the full command, the coordinator must launch the matching development
app once with the variables in `runtime-environment.json`. The runner never
launches an app. Quick acceptance performs headless lifecycle checks and records
the actual-open step as pending. Full acceptance requires a development bundle,
a genuine opened receipt matching the request's identity and digest, and no
remaining open step. A build change invalidates the earlier quick result.
For a packaged CLI, invoke `Contents/MacOS/ed` without resolving its symlink.
The runner verifies the fixed `../Resources/ed-launcher` delegation contract
and `CFBundleExecutable: Edith`, then records a `runtimeIdentity.runtimeHashMap`
for the launcher, actual `Contents/MacOS/Edith` executable, and `Contents/Info.plist`.
`binarySHA256` identifies the actual runtime executable, not the shell launcher.
Quick/full matching requires the complete identity map; launcher-only older
results cannot qualify. Standalone CLIs protect their resolved executable.
Identity is rechecked after each logical phase and immediately before publication.
The same runtime files join the protected mastering/lifecycle artifact snapshot.
Freeze all three packaged paths from quick start through full completion and keep
the launched app on that same frozen build. No shell commands are inferred or
evaluated to discover an arbitrary launcher target.

```sh
python3 scripts/test-editor-parity-identity.py
```

Caption review compares all 47 texts against independently rendered installed
Arial Bold Italic glyphs at the actual output scale, with no fitted rescaling.
The soundtrack adapter verifies native provenance, exact rational timing,
immutable original references, independently measured loudness, every stereo
sample window, and the native PCM mix. Its reference uses measured linear gain
and a sample-exact fade, independently of native two-pass mastering. This is
valid for the synthetic soundtrack because its peak and range need no limiting
or dynamic compression; the native provenance must still report two passes.
AAC copy is a separate small-canvas project with the original compressed
soundtrack. It compares stream durations, delay metadata, every compressed
payload, and exact rational packet times.

Only after these checks does the runner render the main delivery. It decodes
all 5,588 frame timestamps, 30 video picture signatures, first/middle/last photo
samples, all 47 caption pictures, and the final stereo waveform. Full-resolution
caption samples stream through one decoder pass rather than accumulating all
47 uncompressed 4K frames in memory. The full export is attempted once per run.
Failures leave diagnostic artifacts and never publish a full result.

The complete adapters require integrated native verification. Passing the
visual preflight or independent adapter controls alone does not establish
caption, native mastering, compressed-copy, actual-open, or final-export parity.

## Review regression controls

```sh
python3 scripts/test-editor-parity-artifacts.py
python3 scripts/test-editor-parity-grade.py --fixture /absolute/parity-v4
python3 scripts/test-editor-parity-style.py
python3 scripts/test-editor-parity-blending.py
```

Mastered provenance captures exact artifact, project, source, and report bytes.
It is rechecked after native PCM rendering, after lifecycle calls, and immediately
before publication. A metadata-only WAV rewrite with identical decoded PCM is a
failure. `provenanceVerified` is set only after the last protected-artifact check.

The prepared and mastered projects must preserve the literal target controls
`0.002`, `1.02`, and `1.035`. Every photo's first visible frame also has a
target-grade measurement in native review and final delivery. Independent flat
channel samples must distinguish the target from both neutral and stress grades.
Sample selection uses only independent references and codec controls. The
measurement includes a half-code-value rounding budget and refuses insufficient
signal. Existing geometry and glyph tolerances are unchanged.

Caption identity is accompanied by absolute per-line ink boxes, with a two-pixel
edge allowance and no fitted shift. Three full-resolution synthetic blue-card
probes independently exercise 104-point single/two-line and 112-point styles.
Pango/Cairo constructs paths, outlines and the independently colored shadow;
the gradient and glyph layer are composited directly in encoded sRGB code values,
matching the approved Pillow alpha-composite reference. Pango/Cairo generates
the font masks independently; font metrics do not select the blending law.
Gradient, outline, shadow fill/stroke, and antialiased white edges all use
encoded source-over, without decoding a transfer function. The gradient becomes
opaque only below the text, leaving the outline and shadow distinguishable.
Thirteen wrong-style controls cover missing/narrow/wide outlines, missing shadow,
wrong shadow fill/stroke/offset, shifted text, alignment, anchor, line advance,
gradient start and gradient profile. These probes gate complete acceptance in
addition to all 47 original glyph, placement, geometry and contrast checks.
The probes check both native frames and a six-frame encoded sample. Full
acceptance additionally checks styled pixels on all 47 captions in the actual
final 5,588-frame export; the small probes do not substitute for those frames.

`test-editor-parity-blending.py` isolates blending from font geometry. A black
gradient with constant end opacity `100/255` over white must yield RGB 155, over
gray 128 it must yield 78, and over RGB (51, 153, 204) it must yield (31, 93, 124),
each within one code value. The sampled bottom-left region is outside every
glyph and shadow. Linear-light negatives, including the observed old-native
white result 204 (49 levels too bright), must fail. Premultiplied colored-shadow,
outline, and antialiased white-edge controls verify the same encoded law.
The native styled-probe group must also pass these three scalar regions with
the actual caption renderer before it can contribute to an acceptance result.

## Actual public caption creation

`outputCaption` without `id` creates a caption and assigns its native identity.
An explicit `id` updates an existing caption; a nonexistent ID is rejected.
The runner's creation adapter omits IDs and checks the returned captions by
exact anchors, text, and style. It never fabricates native caption identities.

```sh
python3 scripts/test-editor-parity-caption-creation.py \
  --ed /absolute/frozen/ed --workspace /absolute/new/caption-semantics \
  --styled-probe
```

This actual CLI check creates three styled captions, verifies unique assigned
`annotation_<UUID>` identities, updates one through its returned ID, and rejects
an unknown ID after a preceding rename with byte-exact transaction rollback.
The optional styled probe runs the existing three 4K native-frame/export cases
and the scalar encoded-sRGB blend cases with their unchanged tolerances. Scoped
reports declare `productAcceptance: false`; they cannot publish full acceptance.

## Tagged video and background stress

Version 4 explicitly converts synthetic RGB into limited-range BT.709 and sets
frame-level transfer, primaries, matrix and range before encoding. Verification
requires those actual `ffprobe` fields. Earlier v3 videos lost their transfer
and primaries tags despite encoder flags, so v3 is kept immutable and excluded
from this domain check. The runner selects `srgb` for photos and `bt709ToSRGB`
for these tagged videos, whose independent reference interprets the graded RGB
codes as sRGB. It checks all 30 sampled video pictures for target grading as
well as their exact source-frame signatures. Missing domain capability fails
discovery before project creation.

An additional generated background card places a bright stripe just outside
the centered fill crop, a dark crop edge, and high-contrast red/cyan tiles within
the blur support. The independent positive reference crops to the canvas before
blurring encoded sRGB. Separate off-canvas-bleed and linear-blur negatives must
fail. The native background regions must pass both calibrated comparisons and
absolute MAE 8 / p95 24 limits. Existing fixture originals and baselines are not
modified. The probe writes its own diagnostic report on failure and gates both
quick and full acceptance. Visual preflight also records the failed group and
returns a nonzero exit status rather than reporting a complete pass.

```sh
python3 scripts/test-editor-parity-background.py \
  --ed /absolute/development/ed --workspace /absolute/new/background-probe
```
