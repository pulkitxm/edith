# Verification and ledger

## Check state before pixels

After real apply, read `show` and run `validate`. Compare clip order, IDs, source
ranges, speed, canvas, audio and any supported settings with the brief and plan.
Keep the actual returned IDs, not those produced by dry-run. Check that originals
are still present and unchanged. An empty project can validate but cannot provide
a meaningful rendered edit.

## Inspect the rendered edit

Discover `frame` and any `contact-sheet` review command in installed help. Review
the opening, ending, both sides of significant cuts, speed changes, transitions,
caption boundaries, reframing and selected beat accents. Sample output time, not
source time. Request frame starts within the render duration, never its exclusive
end. Read selected frame numbers from review reports when available.

Actually inspect the resulting image files with available image-reading tools.
Look for unintended black or blank frames, clipped captions, wrong orientation,
bad crop, unexpected transition behavior and misplaced overlays. A contact sheet
is a sampling aid; it cannot certify every frame or the audio mix.

For a movie, independently probe the exported file's duration, dimensions, video
codec, pixel format, rational frame rate and audio streams. Decode representative
frames from that actual movie as well as using native project previews. Otherwise
a correct project preview can conceal an incorrect final encode. Compare the
measured properties with the requested delivery settings.

If the process returned zero but the expected file is missing, empty, undecodable
or has mismatched properties, the delivery failed. Report the discrepancy and
fix it before claiming success. Keep prior outputs intact when a replacement
fails. Never use a source asset or the project itself as a render destination.

## Minimal local ledger

Record facts as they become available, with explicit unknowns:

| Area | Record |
| --- | --- |
| Project | Path, identity, variant, saved revision or checksum |
| Source | Logical label, original path, identity/checksum, probe properties |
| Usage | Clip ID, source range, speed, output range, reservation status |
| Audio | Source range, placement clock, gain, mute, loop, cue frames |
| Plan | Plan path, schema version, dry-run result, actual apply result |
| Review | Sampled frames, observed issues, audio checks and limitations |
| Delivery | Output path, measured properties, checksum, verification result |

Keep project paths and private asset details in the local ledger. For shared
evidence, use synthetic assets and sanitized logical labels. Do not publish a
ledger containing real paths or source metadata merely to prove the workflow.

## Completion report

Return the editable project, output artifacts, media dependencies and ledger
location. State what was measured or inspected and what remains unverified.
Distinguish a review proxy from a final deliverable, structural validation from
visual inspection, and measured audio properties from a listening review.
