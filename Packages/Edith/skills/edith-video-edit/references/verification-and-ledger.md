# Verification and ledger

## Check state before pixels

After real apply, read `show` and run `validate`. Compare clip order, IDs, source
ranges, speed, canvas, audio and any supported settings with the brief and plan.
Keep the actual returned IDs, not those produced by dry-run. Check that originals
are still present and unchanged. An empty project can validate but cannot provide
a meaningful rendered edit.

For a batch, compare requested and persisted counts and identities: caption text,
ranges, styles, photo selections and effect parameters. Check each item against its
intended target instead of counting operations alone. Use a supported follow-up
edit on a disposable variant to verify that a caption style or photo effect is
still editable. Rendering baked text or a preprocessed movie does not prove native
editability. Do not replace requested editable content with derived media silently.

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

For an approved visual reference, compare matching output frames at the same
geometry and color interpretation. Inspect crop, padding, blur boundaries, text
layout, shadows and effect strength. Record the comparison method and any agreed
tolerance. FFmpeg and Core Image parameter values are not interchangeable visual
contracts: identical numbers can render different pixels. Tune using rendered
comparisons, and leave an unavailable or subjective approval explicitly unverified.

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
| Requirements | Requested count/behavior, public operation, state evidence, rendered evidence, status |
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

## Register the exact editable project

Registration adds a reference to the canonical original project path. It does not
clone the project, copy its media, rewrite its identity or open the editor. For a
requested library handoff, use the intended installation's CLI:

```sh
ed studio edit register synthetic-cut.openscreen --json
ed studio edit library --json
```

The register result contains `path`, `projectID`, `title` and `registered: true`.
Compare its canonical `path` and `projectID` with the intended project. `library`
returns an array containing native and registered entries. Match the same path
and identity with `registered: true` and no `errorCode`/`error`. A missing or invalid
registered file remains visible with an error; `project_identity_changed` means
the registered path now contains another project. Do not treat the listing's
mere presence as proof that the reference is usable.

`project_id_conflict` rejects an identity already registered at another path.
Inspect both references before deciding whether a deliberate clone or reference
replacement is intended. Do not rewrite project IDs internally to bypass it.
When removal is requested, use `unregister`; it preserves project and media bytes:

```sh
ed studio edit unregister synthetic-cut.openscreen --json
```

Its returned entry has `registered: false`. Check the library again. A native
project can remain listed independently of its removed registration.
For a stale reference, pass the exact stored `path` from `library` to `unregister`.
That pathname takes priority even if the file or a parent directory has since
become a symlink; resolving it to a new target first could select another reference.

## Open only for a requested editor handoff

Normal editing, rendering, review and registration stay headless. When the user
requests the native editor, inspect and validate the chosen project, then issue
one open request for that exact path:

```sh
ed studio edit open synthetic-cut.openscreen --timeout 30 --json
```

`--timeout` accepts 1 through 120 seconds and defaults to 30. The command requires
the CLI's matching app to be running; it does not launch an app. For a development
slot, use `dist/Edith.app/Contents/MacOS/ed` from that slot with its matching app,
not an unbundled `.build` executable or the installed production CLI. If app startup
is needed for the requested handoff, start the matching app once, then retry once
ready instead of repeatedly raising windows.

Success contains `version: 1`, `ok: true`, `state: "opened"`, `requestID`, canonical
`path`, `projectID` and SHA-256 `revision`. The CLI correlates all four request
identity fields. The acknowledgement follows native Studio model mounting and,
for a nonempty project, player readiness. Match path, project ID and revision to
the intended saved edit and retain the request ID. Registration, an existing file
or an already visible window is not this acknowledgement. Opening does not itself
register the project.

Handle structured failures according to their cause:

| Code | Next step |
| --- | --- |
| `app_not_running` | Use the matching running app, only for a requested editor handoff. |
| `editor_busy` | Let the existing open/task finish. Unsaved edits or pending inspector drafts require the user's explicit commit/discard decision before retrying. |
| `missing_media` | Restore or relink the required originals through supported operations; no file dialog is opened. |
| `migration_required` | Use an explicit supported conversion for the legacy document before retrying; do not handwrite its serialization. |
| `project_changed` | Inspect the new saved revision and confirm the intended project before another request. |
| `open_timeout` | Report the missing acknowledgement; do not claim success or repeatedly issue opens. |

Do not use a CLI overwrite to bypass an editor draft or unsaved-change block.
Leave opening unrequested in a headless-only task. Report registration and editor
readiness as separate outcomes with their own returned evidence.
