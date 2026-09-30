---
name: edith-video-delivery
description: Review and deliver Edith .openscreen video edits through the headless ed studio edit CLI. Use when exporting a finished cut, making a contact sheet, checking exact frames or audio sync, producing a full-quality master or review copy, diagnosing a bad render, or handing off an editable project with its media dependencies. Verify the actual encoded artifact before reporting success.
---

# Edith Video Delivery

Produce a reviewable, measured delivery from a native edit. Keep the editable
project and originals intact, and distinguish requested settings from properties
observed in the actual exported file.

## 1. Discover and inspect

Start with:

```sh
ed studio edit --help
ed studio edit schema
ed studio edit render --help
```

Use the executable for the intended installation, including the worktree's own
CLI when testing a development build. Read `show` and `validate` help, inspect
the selected project's `show --summary --json` for IDs, settings and revision,
then use full `show` for style/effect details. Validate sources before rendering. If
locating an existing edit or making a variant, discover `list` and `clone` first.
Do not recreate a native project by writing its internal JSON.

When using an existing Edith MCP connection, discover registered tools first.
Edit tools are generated under `edith_studio_edit_<route>`; use exact advertised
names instead of assuming a route exists. A registered `edith_studio_edit_render`
accepts tool input `{"arguments": ["synthetic.openscreen", "--output", "delivery.mp4"]}`:
the array contains the same arguments/options as the CLI subcommand, without the
`ed studio edit` prefix. JSON output is enabled by the transport. Inspect MCP
`isError` and the payload, including JSON `error.code` and `error.message` for
runtime failures. Parser or transport failures can differ. Discover supported
settings rather than inventing flags from the tool-name pattern.

## 2. Define the delivery contract

Read [full-quality delivery](references/full-quality-delivery.md) before choosing
output settings. Read local `references/` files if the full skill folder is
attached. The Plugins preview and copy contain only `SKILL.md`; for a Markdown-only
attachment, fetch each referenced path from GitHub repository `pulkitxm/edith`,
branch `main`, beneath `Packages/Edith/skills/edith-video-delivery/`. If fetching
fails, use installed help and report the unavailable guidance rather than guessing.

Extract resolution, aspect ratio, exact rational frame rate, duration, container,
codec, audio needs and destination from the brief. Check which controls the
installed help and schema actually expose. Do not assume the default export is
the requested master, or silently reduce quality to make a render finish faster.
Report an unsupported requirement before substituting a different delivery.

Record a requirement ledger with observed evidence and pass, fail or unverified
status. Include reference-image matching, measured loudness, approved audio source,
editable captions/effects and project registration when requested. Read the audio
and passthrough guidance in the delivery blueprint before choosing those modes.
Native mastering has a fixed -16 LUFS recipe and produces PCM. Approved AAC packet
copy is a separate branch using an eligible audio source, never that PCM master.

If native settings must change, build a public plan and use `--expect-revision`
with the inspected revision on both dry-run and atomic apply. Preserve the original
cut when making a separate variant. The `edith-video-edit` skill covers authoring
those plans.

## 3. Render and sample

Create the destination directory. Choose an output distinct from the project,
original media and prior deliveries that should be preserved. Confirm the
installed options before using this baseline sequence:

```sh
ed studio edit show cut.openscreen --json
ed studio edit validate cut.openscreen --json
ed studio edit render cut.openscreen --output delivery.mp4 --json
ed studio edit frame cut.openscreen --time 0 --output opening.png --json
```

Use discovered codec, rate and quality controls when available. Record the actual
command and output path. If a long render's response is lost, inspect its status
and destination before starting another render. Do not treat a timeout as proof
that an export never started or finished.

Read [review and handoff](references/review-and-handoff.md)
for output-frame sampling and measured acceptance. Use `contact-sheet` when help
advertises it, with deliberate times around cuts, transitions, captions and beat
accents. The workflow uses shell and image inspection without opening a player
or requiring mouse interaction.

## 4. Verify the actual artifact

Check the output exists and is decodable. Probe measured duration, dimensions,
codec, pixel format, rational frame rate and audio streams. Decode and inspect
representative frames from the exported movie, not just from the project preview.
Check audio presence, timing and available loudness or peak measurements. State
whether an audible review was possible; measurements alone do not prove the mix.
Compare reference-critical appearance using decoded output frames under matched
geometry and color handling. Equal numeric effect settings do not prove a match.

A zero exit code, a `written` response or a valid project alone is not delivery
verification. A mismatch between requested and measured properties is a failed
acceptance check even when rendering succeeded. Fix the cause and reverify the
affected checks before declaring that requirement met.

## 5. Hand off

Return final and review artifact paths with clear labels, the editable project,
media dependencies, checksums where available, measured properties, sampled
frame positions, and remaining unverified judgments. Keep a local ledger for
repeatability. For shared evidence, use synthetic content and sanitized labels;
do not upload real media or private paths merely to demonstrate a successful run.
Report any requested registration or editor-open acknowledgement separately from
file creation. Use `register` plus `library` for a requested library entry, and
`open` only when the user requests the editor. Check the acknowledgement fields
described in the handoff blueprint; a saved `.openscreen` file proves neither action.
