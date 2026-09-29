---
name: edith-video-edit
description: Edit videos headlessly in Edith with the ed studio edit CLI and native .openscreen projects. Use for assembling footage, exact-frame cuts, reframing, effects, music or voiceover placement, beat-aligned edits, alternate cuts, and organizing or reusing original media. Discover the installed plan schema, apply edits atomically, and verify rendered results without mouse interaction.
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
```

Use the CLI executable for the intended Edith installation. For a development
worktree, use its `dist/Edith.app/Contents/MacOS/ed` instead of the installed `ed`.
Read command-specific `--help` for every command whose options you need. Treat
the installed schema and help as authoritative: operation names, field types,
time units, enum values and delivery settings can differ between installations.
Do not invent flags or send fields merely because the native editor has a feature.

## 2. Establish the edit and its media

Extract the requested aspect ratio, duration, pace, audio intent and deliverables.
Use supplied constraints; ask only about decisions that would materially change
the result. Inspect existing projects with `show`, and discover `list` or `clone`
through help when finding projects or creating an alternate cut.

Read [originals and reuse](https://raw.githubusercontent.com/pulkitxm/edith/main/Packages/Edith/skills/edith-video-edit/references/originals-and-reuse.md)
before importing, reserving or relinking assets. Read local `references/` files
when the full skill folder is available; otherwise fetch the linked blueprint.
The Plugins Markdown preview and copy contain this direction file, so the links
also work when only `SKILL.md` is attached. If a blueprint is unavailable, report
that limitation and use installed help rather than guessing its contract.

Keep originals unchanged. Import their paths into the native project rather than
pre-cutting, resizing, grading or repeatedly encoding intermediate movies. Record
which originals and source ranges each shot uses. Discover any available media
catalog or reservation API before using it. A cloned project may still reference
the same files and may not copy reservations or make the project portable.

## 3. Build a public plan

Read [native plans and time](https://raw.githubusercontent.com/pulkitxm/edith/main/Packages/Edith/skills/edith-video-edit/references/native-plans-and-time.md)
for source versus output time, frame arithmetic, aliases and atomic changes.
Read [audio and beats](https://raw.githubusercontent.com/pulkitxm/edith/main/Packages/Edith/skills/edith-video-edit/references/audio-and-beats.md)
when the edit includes music, voiceover, detached audio or rhythm-driven cuts.

Use the schema's public plan format. Never handwrite internal `.openscreen` JSON.
Batch related operations in a single plan in dependency order, with stable
plan-local aliases for new clips where supported. Reference persisted IDs from
`show` for later plans. Dry-run IDs are previews, not reusable project identities.
Prefer native crop, transform, effects, captions and audio operations when the
schema supports them. If a requested operation is absent, name the limitation
instead of silently substituting a materially different effect or timing model.

## 4. Dry-run, then apply

Create the destination directory first. This baseline sequence uses commands
whose details must be confirmed against the installed help:

```sh
ed studio edit create cut.openscreen --title "Synthetic cut" --json
ed studio edit apply cut.openscreen --plan edit.json --dry-run --json
ed studio edit apply cut.openscreen --plan edit.json --overwrite --json
ed studio edit show cut.openscreen --json
ed studio edit validate cut.openscreen --json
```

Use `create` only for a new project. For an alternate version, use a supported
clone or separate output destination and preserve the original edit. A dry-run
must pass before writing. Apply once as an atomic transaction. On a stale-project
or busy error, reread the project and reconcile the plan before retrying. Do not
automatically replay imports after a lost response: inspect whether they landed.

## 5. Verify and hand off

Read [verification and ledger](https://raw.githubusercontent.com/pulkitxm/edith/main/Packages/Edith/skills/edith-video-edit/references/verification-and-ledger.md).
Inspect project state and actual rendered artifacts, including cut boundaries,
first and last usable frames, overlays, sound and sync. Use `frame` and, when
listed in help, `contact-sheet` for focused review. Sample output time after trim
and speed changes. Process exit zero alone does not establish a correct edit.

For a final export, discover render settings and preserve requested resolution,
rational frame rate and audio quality. A review proxy is not a full-quality
delivery. The separate `edith-video-delivery` skill covers delivery and review.
Return project and output paths, the media ledger, checks actually performed,
and any remaining unsupported operations or unverified audio/visual judgments.
