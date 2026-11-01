# Testing and proof

Verify the source change, the built package, the running extension and the
finished user flow. Record exactly which layers passed. Follow the
[development workflow](development.md) to isolate builds and select the correct
app. Passing a synthetic fixture does not establish real hardware or provider
behavior.

## Select checks from the diff

Install locked dependencies with `bun install --frozen-lockfile`. Refresh
`origin/main` before planning checks, or select an explicit integration base.
The planner includes committed changes since the merge base, local edits and
untracked files.

```sh
git fetch origin main
make ci-local CI_LOCAL='--list'
make ci-local CI_LOCAL='--jobs=2'
```

The default run includes shared policy/script checks, security/workflow checks
and selected product test lanes. Install missing tools using the repository's
`make ci-tools` setup; a missing tool is a failed or blocked check, not a pass.
Use the printed lane names when selecting a rerun:

```sh
make ci-local CI_LOCAL='--list --builds'
make ci-local CI_LOCAL='--builds --jobs=2'
make ci-local CI_LOCAL='--base=origin/main --list'
```

`--builds` adds selected development extension package builds. It does not launch
the slot app, sideload packages or exercise their UI. To rerun a lane, pass
`--lanes=<name>` using a name printed by `--list`. `--no-checks` omits the shared
checks; use it only for a focused rerun after those checks have passed for the
same source. `make ci-local-all` requests every product lane plus package builds
and can be expensive. Do not use it as every worker's default.

Lane logs live in `local/ci-logs/<lane>.log`. Preserve a needed result before the
next run overwrites it. Inspect failures there and rerun the relevant lane after
fixing them. The runner uses local variants for some permission-sensitive lanes;
report those variants accurately and leave the corresponding platform checks
to their intended environment.

## Match tests to the changed contract

| Change | Checks to select | Finished behavior to verify |
| --- | --- | --- |
| Host lifecycle, navigation or CLI | `make ci-host`, routed lanes | Correct slot identity, actual command routing and affected screen flow |
| Marketplace or ABI | `make ci-marketplace-runtime`, `make ci-marketplace-host`, routed scripts | Package admission, load, disable, replacement and expected rejection paths |
| Shared extension support | `make ci-extension-support` and affected dependent lanes | Rebuilt dependent packages load and still perform their operations |
| One extension | Its targets from `make ci-local CI_LOCAL='--list'` | Sideloaded version, live readiness and the changed user operation |
| Packaging or release scripts | `make ci-shipping` and routed script tests | Relevant verified fixture/bundle result; distribution checks where applicable |
| CLI reference | `make ci-docs` | Generated reference remains current and command examples match the implementation |
| Documentation only | Markdown lint and local link review | Commands, paths and limitations agree with current scripts |

Keep regression tests focused on changed behavior: a failure before the fix and
a pass afterwards when practical. Cover meaningful errors and cancellation or
cleanup when those contracts change. Do not add tests that merely search for
the new implementation text. Use the repository's native Make recipes rather
than inventing a shorter Swift invocation that silently omits test frameworks,
plugins, fixtures or environment isolation.

Some extensions need additional native dependencies or services. Inspect the
selected Make recipe and the extension's package before running it. Target
names are explicit and often hyphenated; `make ci-extension-<id>` is not a
universal command template. Backend work has its own Rust and database checks
in [Contributing](../CONTRIBUTING.md).

## Runtime acceptance on the Mac

Use a dedicated slot with synthetic data and mocked external services. Keep the
real product layout, styling, components and behavior. Do not populate a fixture
with copies of actual account history, projects, recordings or private files.
An empty slot alone is insufficient isolation if the feature reads the user's
home directory, clipboard, calendar, running apps or connected accounts. Use
supported fixture paths or a separate synthetic environment for those inputs.

1. Record the checkout commit and whether it has local changes. Stage new source
   files and build the host from that checkout.
2. Launch this slot and inspect `dist/Edith.app/Contents/MacOS/ed app info`.
   Confirm the development bundle identifier and worktree bundle path.
3. Build and sideload dependencies, then the changed extension. Inspect
   `extensions info <id>` with this same CLI and confirm the expected installed
   version, compatibility, enabled state and running state.
4. Run `extensions verify <id> --json`. Inspect the returned checks, readiness
   and live adapter result. A disabled extension or missing permission is not a
   successful feature check. These diagnostic commands can exit zero with
   `verified: false`; evaluate the JSON rather than the process exit alone.
5. Perform the changed operation with synthetic input. Discover supported
   operations through `extensions info <id>` and `schema`, then use the actual
   UI, named CLI route or `invoke` operation as appropriate. Assert the expected
   output or state transition, including a meaningful failure/recovery case.
6. For lifecycle changes, disable and re-enable the extension, repeat the
   operation and restart the slot to check persistence and cleanup. Confirm
   unrelated slot processes and the installed app remain usable.
7. Capture the finished result only after the expected package is active. After
   integrating other checkpoints, repeat these checks on the combined revision.

For UI changes, check compact and regular widths, increased zoom, light and dark
appearance, empty/loading/error states and keyboard focus where affected. If a
feature exports media or documents, open the actual exported artifact and check
its contents. A successful export command alone does not prove a valid result.

When a required hardware device, permission, provider account or visible Mac
session is unavailable, report that exact gap. Keep the checks that did run and
hand off the missing acceptance step. Do not claim end-to-end verification from
a build or mock response.

## Repeatable proof

Keep a local verification record beside the lane logs in ignored `local/`
storage. Include the revision and dirty status, slot identity, extension ids
and versions, test commands with actual outcomes, synthetic fixture setup,
expected versus observed user result, and any remaining acceptance gaps.
Record the host ABI when compatibility is relevant. Exclude secrets and real
project data. This record ties an artifact to the tested source; app version
alone does not identify a branch build.

A useful handoff says which checkpoint to integrate, what changed, the commands
that passed, what was exercised in the running package, the proof location and
what still needs another environment. The integration owner records the same
information for the final combined revision. Worker evidence describes worker
results only until that integration pass succeeds.

## Review evidence

Post evidence once the work is finished and verified, as a separate Pukbot
comment on the PR. The description stays a single line. Use one evidence comment
by default, at most two or three when distinct outcomes need separate captures.
Keep the text lowercase and short, with the artifact and a line explaining the
finished result. Pure documentation, configuration or refactor changes with
nothing meaningful to demonstrate can omit visual evidence.

| Outcome | Suitable proof |
| --- | --- |
| Final UI | Screenshot from the actual product running synthetic fixtures |
| Interactive flow | Short recording of the completed flow and final state |
| CLI or backend behavior | Sanitized final command output showing input, result and relevant assertions |
| Export or rendering | Finished synthetic artifact and its inspected result |
| Visual fix | Before and after captures using the same synthetic fixture |

Build logs and intermediate debugging output do not show a finished feature.
Readiness alone establishes readiness, not the changed operation. Include the
actual result a reviewer needs to assess without running a dev server.

Never upload an original laptop capture containing actual project data, even to
a private destination or an external sanitization tool. Create fresh captures
from the isolated synthetic run. Presenter mode, blurring and cropping an
original are insufficient substitutes. For terminal evidence, sanitize a local
text copy while preserving the actual outcome and structure. Review every final
artifact for credentials, personal information, real project data, private paths
and metadata before uploading. Do not invent successful output or substitute a
mockup for a product capture. If safe evidence cannot be produced, explain the
specific limitation.

## Release verification boundary

Development sideloading deliberately uses ad-hoc packages. It verifies local
package loading and feature behavior, but does not establish Developer ID trust,
notarization, Gatekeeper acceptance, signed catalog publication, Sparkle updates
or production daemon registration. Use the routed release/package tests and a
scheduled signed-release acceptance pass for those contracts. Keep production
installation owned by one coordinator; ordinary workers use their own slots.
