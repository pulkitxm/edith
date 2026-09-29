# Native plans and time

## Work in the public edit interface

Save a small public plan beside its inputs. Run `ed studio edit schema` before
writing it and check operation-specific fields instead of copying internal
project serialization. Apply plans in dependency order: import, establish source
ranges, arrange shots, then place dependent regions and adjust presentation.
Batch a coherent change so validation can reject the whole edit without leaving
half an arrangement behind.

In the baseline interface, a plan looks like this when `synthetic.mov` contains
at least two seconds of native-decodable video:

```json
{
  "version": 1,
  "operations": [
    {"addMedia": {"path": "synthetic.mov", "name": "opening"}},
    {"trim": {"clipID": "opening", "start": 0.25, "end": 1.75}}
  ]
}
```

Relative media paths resolve beside the plan, not beside the project or shell
working directory. Quote shell paths. Persisted projects reference source files;
keep those files available after the planning session ends. Plan-local aliases
are convenient inside one apply. Read returned aliases and `show` after the real
apply before creating a follow-up plan.

## Keep the clocks separate

Write down three clocks for every time-sensitive edit:

| Clock | Meaning | Typical use |
| --- | --- | --- |
| Source | Position in an original asset | Trim and split |
| Project ruler | The native placement model declared by the operation | Annotations, anchored audio or regions |
| Rendered output | Position after trims, speed and arrangement | Review frames, delivery duration, independent audio if supported |

Do not infer an operation's clock from the word `start`. Baseline text and
clip-anchored audio use the native source-time ruler. Newer independent audio or
marker operations may use output frames. Read the installed contract before
translating one to another. A speed change can move a beat or overlay in output
time even when its source-time coordinate has not changed.

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

Do arithmetic with rational values until an API requires seconds. If the CLI
offers integer frames, prefer them for exact cuts and markers. If it only accepts
seconds, calculate once, record the rounding convention, and verify which frames
were selected. A decimal `29.97` is not an exact replacement for `30000/1001`.
Source frame rate and delivery frame rate may differ. Record both rather than
using an output frame number as a source frame number.

After a trim, speed or frame-rate change, recompute dependent output positions and
resample boundaries. Do not reuse stale timing calculations from the old cut.

## Recover without duplicating edits

A dry-run validates and probes in memory; it does not reserve IDs or write the
project. Use its diagnostics to revise the entire plan, then apply that plan
once. An in-place apply needs explicit overwrite permission. A separate output
preserves the source project. Never use an original media path as an output.

If the project changed during validation, load the new revision and compare its
IDs and ordering with the planned input. Resolve the conflict before another
apply. If a response was lost, inspect the current project before repeating an
import or append operation.
