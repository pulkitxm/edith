# Native plans and time

## Work in the public edit interface

Save a small public plan beside its inputs. Run `ed studio edit schema` before
writing it, then use `schema --operation NAME` for the operation-specific entry
instead of copying internal project serialization. For example:

```sh
ed studio edit schema --operation visualEffects
ed studio edit show cut.openscreen --summary --json
```

The summary includes `projectID`, `path`, `title`, `revision`, `settings`,
`clipIDs`, `audioIDs`, `captionIDs` and `assetCount`. Its `revision` is the saved
project bytes' SHA-256. Use full `show` when planning changes to details the summary
omits. Apply plans in dependency order: import, establish source ranges, arrange
shots, then place dependent regions and adjust presentation.
Batch a coherent change so validation can reject the whole edit without leaving
half an arrangement behind.

Plans have at most 1000 operations and 4 MiB of JSON. A batch within those limits
can use one transaction; larger batches need coherent checkpoints and fresh IDs
and revisions between them.

A plan looks like this when `synthetic.mov` contains at least two seconds of
native-decodable video:

```json
{
  "version": 1,
  "operations": [
    {"addMedia": {"path": "synthetic.mov", "name": "opening"}},
    {"trim": {"clipID": "opening", "start": 0.25, "end": 1.75}}
  ]
}
```

For file plans, relative media paths default to the plan's directory. For stdin
plans (`--plan -`), they default to the shell working directory. Use
`--media-directory BASE` to explicitly set the media base for either input form;
it must be an existing local directory. Quote shell paths. Persisted projects
reference source files; keep them available after the planning session ends. Plan-local aliases
are convenient inside one apply. Read returned aliases and `show` after the real
apply before creating a follow-up plan.

For example, keep the plan at `plans/edit.json` and its original media under
`synthetic-media`. With `jq` available, use stdin with the same explicit base and
expected revision for both runs:

```sh
revision=$(ed studio edit show cut.openscreen --summary --json | jq -er .revision)
ed studio edit apply cut.openscreen --plan - --media-directory synthetic-media --expect-revision "$revision" --dry-run --json < plans/edit.json
ed studio edit apply cut.openscreen --plan - --media-directory synthetic-media --expect-revision "$revision" --overwrite --json < plans/edit.json
```

Proceed to the write only if the dry-run succeeded. Preserve the plan file for
repeatability even when using stdin. MCP callers pass that file with `--plan`
through the tool's `arguments` array; do not use `--plan -` for MCP.

## Keep the clocks separate

Write down three clocks for every time-sensitive edit:

| Clock | Meaning | Typical use |
| --- | --- | --- |
| Source | Position in an original asset | Trim and split |
| Project ruler | The native placement model declared by the operation | Annotations, anchored audio or regions |
| Rendered output | Position after trims, speed and arrangement | Review frames, delivery duration, independent audio placement |

Do not infer an operation's clock from the word `start`. The `text` annotation
operation uses the native source-time ruler, while independent audio placement
uses output seconds and its source offset uses original audio seconds. Read each
caption or marker operation's declared clock before translating it. A speed change
can move a beat or overlay in output time even when a source coordinate is unchanged.

For constant-speed footage, an output offset from the start of a trimmed clip is
`(sourceTime - sourceIn) / speed`. Add the preceding clips' output durations to
locate it in the finished sequence. Confirm transition timing from the native
model; do not assume every transition is an overlapping dissolve. Fade-through-
color transitions are visibly different from a cross-dissolve.

## Use frames and rational rates

Keep a rate such as `30000/1001` as a numerator and denominator. Frame `n` starts
at `n * denominator / numerator` seconds. For a duration of `N` output frames,
the last frame starts at `(N - 1) * denominator / numerator`, not at the duration.
Use zero-based frame numbers and half-open ranges `[in, out)` in the planning
ledger, then translate to the operation's documented convention.

Do arithmetic with rational values until an API requires seconds. Set the exact
project cadence using `videoSettings` fields from the schema. For review, prefer
`frame --frame INDEX` to rounding seconds; `--time` selects the preceding frame.
For a seconds-based trim, calculate once, record the rounding convention, and
verify which frames were selected. A decimal `29.97` is not an exact replacement
for `30000/1001`.
Keep integer frame indices for frame-anchored operations. When a field requires
seconds, serialize the calculated value at full JSON numeric precision; do not
round it through a display string such as three-decimal seconds. Compute audio
endpoints from the same rational output duration, then verify saved ranges and
delivered boundaries. Review-time frame selection is distinct from edit-time
conversion, so use `--frame` for exact samples rather than assuming a seconds
request uses the same rounding rule as a trim.
Source frame rate and delivery frame rate may differ. Record both rather than
using an output frame number as a source frame number.

After a trim, speed or frame-rate change, recompute dependent output positions and
resample boundaries. Do not reuse stale timing calculations from the old cut.

## Recover without duplicating edits

A dry-run validates and probes in memory; it does not reserve IDs or write the
project. Use its diagnostics to revise the entire plan, then apply that plan
once. An in-place apply needs explicit overwrite permission. A separate output
preserves the source project. Never use an original media path as an output.

Pass `--expect-revision SHA` from the project snapshot used to construct the plan.
A mismatch returns `project_changed` before any operations run, including during
`--dry-run` or a fork using `--output`. Apply results include `sourceRevision` and
the resulting `revision`. During dry-run both identify the unchanged source, not
a future saved revision. After a real apply, retain the saved revision and actual
IDs for the next transaction. A dry-run succeeding does not lock the project until
the write; keep the guard on both calls.

With `--json`, successful result JSON goes to stdout and runtime error JSON goes
to stderr. A failed operation includes zero-based `error.operationIndex` and
`error.cause`, the underlying error code, alongside `error.code` and
`error.message`. Index 1 identifies the second operation. Schema errors instead
identify unknown/missing fields with their JSON path. Neither failure commits
earlier operations. Correct the plan as a unit, not by replaying only its tail.

If the project changed during validation, load the new revision and compare its
IDs and ordering with the planned input. Resolve the conflict before another
apply. If a response was lost, inspect the current project before repeating an
import or append operation.

Complete a requested failure-and-recovery exercise on the same disposable project.
After the intentional rejection, retain its diagnostics and unchanged project hash,
then reread the summary and any affected details. Correct the full plan, dry-run
against that current revision, and perform the corrected guarded apply. Inspect
the resulting saved state and validate it. Record the successful repair separately
from the rejected attempt; a failed operation followed only by `show` proves the
failure preserved state, not that the correction works. If repair cannot finish,
leave recovery failed or unverified rather than counting rejection as completion.
