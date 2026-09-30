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
