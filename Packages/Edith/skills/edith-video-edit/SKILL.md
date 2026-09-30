---
name: edith-video-edit
description: Edit videos headlessly in Edith with the ed studio edit CLI and native .openscreen projects. Use for assembling footage, exact-frame cuts, batch captions and styles, photo backgrounds and effects, independent music or voiceover, beat-aligned edits, alternate cuts, and organizing original media. Discover the public plan schema, apply edits atomically, and verify editable state and rendered results without mouse interaction.
---

# Edith Video Edit

Turn a brief and original media into a native, editable project through the public
CLI. Keep a reproducible plan and media ledger alongside the project. Work through
shell commands and artifact inspection; the workflow does not require a window.

## 1. Discover before planning

Start with:

```sh
ed studio edit --help
ed studio edit schema
ed studio edit schema --operation visualEffects
```

Use the CLI executable for the intended Edith installation. For a development
worktree, use its `dist/Edith.app/Contents/MacOS/ed` instead of the installed `ed`.
Read command-specific `--help` for every command whose options you need. Treat
the installed schema and help as authoritative: operation names, field types,
time units, enum values and delivery settings can differ between installations.
Do not invent flags or send fields merely because the native editor has a feature.
Use `schema --operation NAME` for the exact schema of one operations-array entry.

When using an existing Edith MCP connection, discover its registered tools first.
Edit tools are generated under `edith_studio_edit_<route>`; use the exact advertised
name rather than assuming every CLI route is registered. For example, the
registered `edith_studio_edit_validate` takes tool input
`{"arguments": ["synthetic.openscreen"]}`. This array contains the same positional
arguments and options as the CLI subcommand, without the `ed studio edit` prefix.
The transport enables JSON output. Inspect the MCP `isError` result and payload:
runtime failures include JSON `error.code` and `error.message`; parser or transport
failures can differ. Discover supported arguments instead of inventing flags.
For MCP apply calls, pass a saved plan file in `arguments`; CLI stdin is not an
MCP plan transport.

## 2. Establish the edit and its media

Extract the requested aspect ratio, duration, pace, audio intent and deliverables.
Use supplied constraints; ask only about decisions that would materially change
the result. Inspect existing projects with `show --summary --json` for their
identity, persisted IDs, settings and SHA-256 revision. Use full `show --json` for
effect/style details. Discover `list` or `clone` through help when finding projects
or creating an alternate cut.

Make a requirement ledger before editing: requested outcome, public operation,
persisted-state check, rendered check and status. Include batch counts, editable
styles/effects, reference appearance, audio targets and project registration when
requested. A successful apply does not satisfy requirements left out of the plan.

Read [originals and reuse](references/originals-and-reuse.md) before importing,
sorting by capture date, reserving or relinking assets. Read local `references/`
files when the full skill folder is available. The Plugins preview and copy contain
only `SKILL.md`; for a Markdown-only attachment, fetch each referenced path from
GitHub repository
`pulkitxm/edith`, branch `main`, beneath
`Packages/Edith/skills/edith-video-edit/`. If a blueprint is unavailable, report
that limitation and use installed help rather than guessing its contract.

Keep originals unchanged. Import their paths into the native project rather than
pre-cutting, resizing, grading or repeatedly encoding intermediate movies. Record
which originals and source ranges each shot uses. Discover any available media
catalog or reservation API before using it. A cloned project may still reference
the same files and may not copy reservations or make the project portable.

## 3. Build a public plan

Read [native plans and time](references/native-plans-and-time.md)
for source versus output time, frame arithmetic, aliases and atomic changes.
Read [audio and beats](references/audio-and-beats.md)
when the edit includes music, voiceover, detached audio or rhythm-driven cuts.
Read [photo backgrounds and effects](references/photo-backgrounds-and-effects.md)
for independent foreground/background geometry, replacement semantics and explicit
`native` versus `ffmpeg709` grading. Choose a mode compatible with the approved
reference's color pipeline, then verify representative rendered frames.

Use the schema's public plan format. Never handwrite internal `.openscreen` JSON.
Batch related operations in a single plan in dependency order, with stable
plan-local aliases for new clips where supported. Reference persisted IDs from
`show` for later plans. Dry-run IDs are previews, not reusable project identities.
Prefer native crop, transform, effects, captions and audio operations when the
schema supports them. If a requested operation is absent, name the limitation
instead of silently substituting a materially different effect or timing model.
Keep captions, per-caption styles and photo effects independently editable when
requested. A flattened replacement movie is not equivalent to a native edit.

## 4. Dry-run, then apply

Create the destination directory first. For a new project and a saved public plan,
capture the revision and use it for both dry-run and apply. This example uses `jq`:

```sh
ed studio edit create cut.openscreen --title "Synthetic cut" --json
revision=$(ed studio edit show cut.openscreen --summary --json | jq -er .revision)
ed studio edit apply cut.openscreen --plan edit.json --expect-revision "$revision" --dry-run --json
ed studio edit apply cut.openscreen --plan edit.json --expect-revision "$revision" --overwrite --json
ed studio edit show cut.openscreen --summary --json
ed studio edit validate cut.openscreen --json
```

Use `create` only for a new project. For an alternate version, use a supported
clone or separate output destination and preserve the original edit. A dry-run
must pass before writing. Apply once as an atomic transaction. On a stale-project
or busy error, reread the project and reconcile the plan before retrying. Do not
automatically replay imports after a lost response: inspect whether they landed.
Keep the apply result's saved `revision` for the next guarded edit. On an operation
failure, inspect zero-based `error.operationIndex` and `error.cause` before revising
the whole plan. Read the plan blueprint for stdin and explicit media-base examples.

## 5. Verify and hand off

Read [verification and ledger](references/verification-and-ledger.md).
Inspect project state and actual rendered artifacts, including cut boundaries,
first and last usable frames, overlays, sound and sync. Use `frame` and, when
listed in help, `contact-sheet` for focused review. Sample output time after trim
and speed changes. Process exit zero alone does not establish a correct edit.

For requested library handoff, use `register` and verify the exact entry in
`library`. Use `open` only for a requested editor handoff, with the matching app
running, and require its exact-project acknowledgement. The verification blueprint
covers result fields and recovery. Routine editing and review stay headless.

For a final export, discover render settings and preserve requested resolution,
rational frame rate and audio quality. A review proxy is not a full-quality
delivery. The separate `edith-video-delivery` skill covers delivery and review.
Return project and output paths, the media ledger, checks actually performed,
and any remaining unsupported operations or unverified audio/visual judgments.
Mark every requirement passed, failed or unverified using the recorded evidence.
