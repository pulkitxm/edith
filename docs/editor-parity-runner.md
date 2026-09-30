# Complete synthetic editor parity runner

The runner uses only generated fixtures and the explicitly supplied development
CLI. It must finish all required groups before publishing full acceptance.

## Version 3 fixtures

```sh
python3 scripts/editor_parity_fixtures.py generate /absolute/new/parity-v3
python3 scripts/test-editor-parity-motion.py \
  --fixture /absolute/parity-v3 --workspace /absolute/new/motion-controls
```

Version 3 retains 47 originals, 42 photos, five videos, 47 captions, and 5,588
frames at 60 fps. Every video has an independently chosen nonzero source trim,
with enough original frames before and after the selected range. Its visible
frame signatures prove the exact source position, not just output timestamps.

Eighteen contained photos remain static. Twenty-three fill photos zoom linearly
from 1 to 1.025 and one from 1 to 1.012. The focal fill region is selected first,
then zoomed about that selected crop's center. This preserves both off-center
focal selections without anchoring motion to the uncropped original center.
The final visible frame samples fraction `(frames - 1) / frames`; the endpoint
keyframe is at the exact shot duration. No replacement image is generated for
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
  --ed /absolute/development/ed --fixture /absolute/parity-v3 \
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
  --ed /absolute/Edith.app/Contents/MacOS/ed --fixture /absolute/parity-v3 \
  --workspace /absolute/new/quick --mode quick
python3 scripts/test-editor-parity-runner.py \
  --ed /absolute/Edith.app/Contents/MacOS/ed --fixture /absolute/parity-v3 \
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
python3 scripts/test-editor-parity-grade.py --fixture /absolute/parity-v3
python3 scripts/test-editor-parity-style.py
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
the gradient is composited in linear sRGB over the known background. It becomes
opaque only below the text, leaving the outline and shadow distinguishable.
Thirteen wrong-style controls cover missing/narrow/wide outlines, missing shadow,
wrong shadow fill/stroke/offset, shifted text, alignment, anchor, line advance,
gradient start and gradient profile. These probes gate complete acceptance in
addition to all 47 original glyph, placement, geometry and contrast checks.
