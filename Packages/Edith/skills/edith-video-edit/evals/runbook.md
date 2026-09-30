# Executed workflow evaluation

Use the two edit cases in `evals.json` and the delivery case in
`../../edith-video-delivery/evals/evals.json` as one three-case suite. Compare the
updated folders with a snapshot of both old skill folders. Run both configurations
against the same integrated development CLI and equivalent fresh synthetic inputs.
An old-skill run must use the current executable too: the comparison measures
guidance, not different product implementations.

## Fixture preparation

Create fixtures in an isolated temporary directory with no real project data.
Use generated color cards, shapes, caption text, tones and known audio cues. Record
the generator settings and checksums in a fixture manifest. Build all native
projects through the actual public CLI, never internal project serialization.
Keep each configuration's working outputs separate. Confirm the intended CLI
supports the integrated contracts before starting the comparison; record its
version, help and schema rather than substituting simulated responses.

| Case | Inputs to prepare |
| --- | --- |
| 1: Batch editability and reference matching | Nine distinguishable photos, 23 caption entries with exact output ranges and differing styles, an approved independent tone bed, a canonical-export sentinel and synthetic approved reference frames. Specify geometry, color interpretation, comparison regions and numeric tolerances before either run. |
| 2: Recovery and guarded editing | Launch and previous projects referencing a generated motion clip with known source-time cues, plus independent music. Apply the interrupted import using the real CLI and withhold its stdout from the runner; retain the result for grading. The previous project uses a strict subset of available source ranges. |
| 3: Measured delivery and packet compatibility | A short native project with generated stereo audio and known cues, approved-source checksums, a genuine wrong-size/wrong-rate/silent review file, a canonical-export sentinel, reference frames and AAC candidates with compatible versus incompatible packet configuration. Record actual packet metadata for both. |

Generate references independently of the candidate result. Do not approve the
runner's first render as its own reference or adjust tolerances after seeing it.
For audio, use enough duration for the chosen loudness meter and include a changing
envelope so a guessed gain is distinguishable from measured correction. Keep the
clips short and the render dimensions modest; these are workflow checks, not
throughput benchmarks. Have a fixture verifier establish expected properties before
the runs. Do not count fixture preparation as successful task execution.

## Run and retain

For each case and configuration, provide the corresponding skill folder, prompt,
fixture directory and explicit executable path. The runner must execute the task
and retain these artifacts in its own output directory:

- Exact commands, exit codes, stdout and stderr, including help and schema queries.
- Public plans, dry-run responses, apply results and final project inspection.
- Before/after hashes for originals, canonical outputs and protected projects.
- Final encoded files, independent media probes, decoded frames and comparisons.
- Audio measurements, approved-source provenance and delivery-mode reports.
- A requirement ledger linking every claimed outcome to an artifact.

Do not open an app, player or browser. A registration check may use an isolated
development service if already available, but it must not start the GUI. Otherwise
record that check as unverified. Registration and editor-open acknowledgement are
distinct; this suite intentionally leaves editor opening unrequested.

Case 2's stale-revision exercise must create a real intervening public edit on a
disposable copy. Preserve the stale token, then attempt guarded dry-run and fork
operations and inspect both source and destination afterward. For the bad second
operation, use a schema-valid operation targeting a nonexistent persisted ID after
a valid first operation, so execution diagnostics and atomic rollback are tested.
Never fake an error result or count a schema parse failure as operation rollback.

## Grade artifacts, then compare

Check expectations against commands and saved outputs, not prose assurances. Use
independent project inspection, hashes, media probing, loudness measurements and
frame comparison where applicable. A command sequence proposed but not executed
does not pass an execution expectation. A correctly reported unsupported feature
may pass honesty checks but does not pass feature-completion checks.

Record each expectation as passed, failed or blocked with the precise artifact
and observation. Preserve blocked reasons separately from failures so an absent
integrated binary or service cannot masquerade as a guidance regression. Record
duration and token counts only from actual run metadata when available.

Summarize old versus new completion, correctness and false-success claims. Build
the standard static evaluation review from actual outputs and grading results;
do not open it automatically. Keep evidence local unless it has been checked for
synthetic-only content and sanitized paths. Do not publish placeholders, fabricated
task answers or passing results for runs that have not happened.
