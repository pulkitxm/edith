# Extension marketplace migration status

The migration is not ready to merge. The small app host and marketplace source
are integrated, and genuine hosted Host/Core/UI tests have passed. Complete
current extension journeys, all required CI checks and public releases remain
unfinished.

## Size comparison

The clean empty host measured 9,409,404 bytes, or 9.41 decimal MB, from source
`26a500e0421bf579473149e1fde2232841ff4c33`. It contains zero optional extension
payload and is 92.85% smaller than the recorded 131,607,239-byte bundled baseline.
The controlled comparison ZIP is 4,900,836 bytes. This is an ad-hoc signed arm64
Release measurement, not the final signed shipping app or DMG.

| Measured empty host component | Bytes |
| --- | ---: |
| Host and CLI | 7,527,136 |
| Sparkle updater | 1,441,041 |
| Icons, index and resources | 434,809 |
| Metadata and signatures | 6,418 |
| Total logical app size | 9,409,404 |
| Allocated regular-file size | 9,551,872 |

The earlier complete package set, measured from source
`bc66feff460780b624cafc26bfed02a2b29ed9ca`, contains 39 independent downloads.

| Earlier local artifact measurement | Bytes |
| --- | ---: |
| Extension ZIPs | 468,938,701 |
| Expanded extension packages | 951,938,618 |
| Metadata and checksum files | 23,353 |
| Complete extension release assets | 468,962,054 |
| Earlier host plus all expanded packages | 960,784,006 |

These package measurements are historical local artifacts. They are not current
published GitHub asset sizes. Independent packages duplicate signed carriers and
some libraries, so installing all extensions can use more disk than the former
bundled app. The small empty app and selective installation avoid paying that
storage cost for unused features.

See the [current size report](extension-marketplace-current-size.md),
[exact measurement data](extension-marketplace-current-size.json),
[earlier per-extension measurements](extension-host-rebuild-size-report.md) and
[regeneration procedure](extension-host-rebuild-measurements.md).

## Product contracts

The app retains the original navigation and installed extension pages. Home and
Notch layout controls remain in the host. Uninstalled pages stay out of
navigation, and disabled providers retain saved layouts without active cards.

Onboarding lives inside the app and recommends editable selections for Agentic,
Creative, Developer, Essentials or Custom workflows. Users review each package
and its download and installed sizes. Dependencies count once.

Disabling stops owned work and internal workers while retaining package files.
Removing waits for leases and cleanup before deleting package versions. Feature
data and agentic usage history remain separate and retained.

Sparkle updates the app. Independent signed catalog packages update extensions.
Compatibility checks cover ABI, architecture and full macOS version. Failed
replacement retains a usable prior version when available. Existing verified
packages and cached metadata support offline use.

Storage distinguishes logical bytes, allocated files, catalog estimates, package
versions, repeated carriers/frameworks, retained data and known caches or
deployment copies. Allocated bytes do not measure exclusive physical APFS usage.

Separate releases use production fingerprints and dependency closure. Test-only
edits do not change shipping versions. Shared runtime changes can correctly
rebuild several owners. A host release requires a compatible published catalog.

These contracts have source and focused tests. The complete current product
journey is still a required acceptance gate.

## Verification completed

At source `abb481d60ee17ab83b15ec5fb176718f27efb248`, hosted `make ci-host`
executed 809 tests in 136 suites and passed in 179.276 seconds. Original Home
controls and compact/regular layout editors with zoom were exercised.

A separate hosted diagnostic passed Core 519 tests in 94 suites, UI 290 tests
in 42 suites and transport 9 tests. Its later MarketplaceHarness compilation
failed. Core plus UI overlap the same 809-test set and are not additional unique
tests.

The harness compiler setting has since been corrected and the actual native
harness compiled successfully. The generated host ABI was renewed, and its
47 focused ABI/release-planning tests passed with 931 expectation calls.

The coherent hosted producer, regular evidence models, owned socket cleanup
and source normalizer are now integrated. Their complete package and test
targets compile with warnings treated as errors and pass strict formatting.
The finite Calendar Context, RequestJournal and contract-test supplement is
also integrated and compiled. The original Calendar action and downstream
receipt consumers remain incomplete.

Focused lifecycle, settings, saved-state, parser and release tests cover scoped
behavior. Module compilation and pure model tests do not establish the complete
39-extension native journey or publication.

Native product tests run with synthetic fixtures on disposable macOS runners.
Local product windows and actual user preferences, Keychain or agentic data are
not used for this verification.

## Current failures and unfinished behavior

| Area | Outstanding result | Required correction |
| --- | --- | --- |
| Attention | Target feature corrected; native and test-target compilation passed | Verify current hosted original tests and archives |
| Machines | Expected usage completion receipt absent at the original timeout | Diagnose completion and ownership, preserve timing |
| Camera | Native tests passed, then a generated lockfile failed source admission | Account for legitimate dependency inputs without weakening admission |
| Terminal | Upload files remained after disable | Restore actual owner cleanup and join active copies |
| Studio | Original export exceeded 30 seconds | Optimize the actual exporter with original 120-clip and frame requirements |
| Calendar | Original local Details receipt path incomplete | Consume genuine local UI and unchanged backend observations |
| Docs | Library array and answer object require distinct capture | Validate actual rendered answer and independent library state |
| Keep Awake | Original preparation schema missing in functional fixtures | Add finite engine/UI plist preparation |
| Output owners | Typed outcome helpers are not all consumed | Capture and validate actual PTY, decoded media and file results |

The AppMaintenance ownership assertions have a scoped correction for the current
joined stop helper. Its actual current native result still needs requalification.
A later feature-models run also failed three admission/roundtrip cases with
invalidRequest. The integrated Peer correction now joins retired generations
before reopening command admission and adds a held-work restart regression.
Both complete package configurations compile, while the original three hosted
restart tests and the new regression still require current runtime verification.
Additional current CI logs remain part of final verification.

ArgumentParser deprecations originate in pinned support source copied into each
namespaced extension module. The integrated generator correction targets the deprecated
prefix and completion mapping while retaining current custom-prefix behavior.
The 19 focused regression tests passed. All 53 transformed parser sources
compiled with warnings treated as errors.
Remaining warning migrations include deprecated AppKit accessibility helpers
in tests, unused weak variables, redundant optional/effect markers and supported
SwiftPM build-system configuration. The complete warning inventory and final
extension archive builds remain to be qualified. No warning suppression or removal of original tests is an acceptance
substitute.

## Original time foundations

Studio must retain 120 clips, 120 seconds, 30fps, 3600 decoded output frames and
the original export limit of 30 seconds. The current failure remains a failure.
Synthetic source-media preparation is not proof of the original export.

TimeLapse retains all five original suites and the original 30/60fps, audio,
timing and quality assertions. Original scheduler and owner drain bounds remain
intact. Increasing timeouts or reducing fixtures is not an accepted correction.

## Remaining acceptance order

1. Consolidate coherent reviewed source and dependencies into the final branch.
   Correct the current compiler, cleanup and completion failures. Recheck ABI,
   fingerprints, formats, comments and links after production changes.
2. Finish original Calendar, Docs, Keep Awake and Studio paths. Consume finite
   native outcome relations for Terminal, TimeLapse and BlitzTree. Reconcile
   original recipe hashes against the current source.
3. Execute all 39 owners through initial install, update and reinstall. Require
   117 real owner-phase actors, original controls, actual independent state,
   retained synthetic data, package removal and natural worker retirement.
4. Verify onboarding, hidden navigation, Home/Notch availability, storage,
   offline use, failed updates and rollback in the actual product.
5. Build and measure the final signed app, shipping DMG and all current package
   assets. Verify actual public URLs, bytes, checksums, publisher identity,
   catalog compatibility and selective rebuild behavior.
6. Publish finished synthetic product evidence only after those gates pass.
   Squash merge the ready PR and validate main releases and real downloads.

The final PR remains a draft until these results are established. Historical
sizes, partial CI success and source-only readiness must remain visibly distinct
from complete current native and public-release proof.
