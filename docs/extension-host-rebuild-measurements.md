# Host rebuild measurement procedure

The JSON and Markdown size reports describe the exact local artifacts measured at their recorded time. Regenerate them only after the final integrated host and all indexed worker packages have been built and verified. A complete set of 39 indexed packages changes package coverage to `all-indexed-packages-measured`; it does not establish merge readiness, production signing, successful lifecycle tests, or release publication.

The generator validates ZIP length, SHA-256, expanded package bytes, CRC, and current package source fingerprints. It rejects missing, extra, duplicate, changed, or stale package artifacts. Build every indexed package into `dist/extensions` before measuring complete coverage. The final report must use the current integrated source fingerprints, rather than packages retained from earlier checkpoints.

Installed bytes mean logical regular-file bytes. App comparison ZIPs use deflate level 9 and exclude symlinks, matching the retained baseline method. Host-plus-package totals count the host and one package version per feature. They exclude filesystem allocation rounding, receipts, caches, user data, previous package versions, and extra OS-managed deployment copies. Camera uses an independently installed OBS Virtual Camera provider. Its optional Edith Microphone driver installation can add a copy outside the measured package directory; the OBS installation is an external prerequisite and is not part of Edith's download.

ZIP and JSON metadata totals describe local artifacts. They exclude detached checksums, the shared signed catalog, and retained release versions. Generating a report does not upload or publish anything, and does not prove that matching assets exist on GitHub or that clients can download them. Record release publication and cloud download checks separately.

Use the actual baseline build metadata in `local/baseline/current-main-size.json`. The retained baseline at source commit `91d0e13de56aaf297ad4630d2c36ef124da5bf0c` records Release, arm64, ad-hoc signing, Xcode 27.0 (27A266a), SDK 27.0, and the pinned Ghostty source commit. Ad-hoc signing is distinct from production signing. Do not label a Release baseline as a Debug or production-signed app, or infer the host's build configuration from the baseline.

For the freshly built host, record a local JSON file at `local/minimal-host/build-metadata.json` with `sourceCommit`, `configuration`, `optimization`, `architecture`, `signature`, `xcode`, `sdk`, and `hostExecutableSHA256`. Populate these from the build command, selected toolchain, signing operation, architecture inspection, and SHA-256 of `Contents/MacOS/Edith`. Optional `ghosttySourceCommit` and `ghosttyArchive` fields apply only when relevant to that build. The generator accepts host provenance only when the executable checksum matches the measured file. It does not independently certify the supplied configuration or verify code signatures. If provenance is missing, omit `--host-build`; the report records the missing information without assuming values.

The lightweight development host build uses Release with `-Osize`, arm64, and ad-hoc signing. Record the actual source commit and toolchain used for the final build. Run the appropriate host build or shipping verifier to check signatures, dependency boundaries, absence of feature payload, and the unchanged requirement that the empty host remain below 5,000,000 installed bytes. Size-report generation does not replace these checks.

Worker lifecycle checks must separately verify app replacement, extension update, restored preferences and layouts, disable, and removal. Native tasks require the owning worker's live capability, the same signed host executable, kernel peer identity, and owned process groups. Teardown checks cover workers, admitted native tasks, and registered command or descendant groups. Arbitrarily detached, unregistered feature processes are outside this contract.

Camera uses the existing [OBS Virtual Camera](https://obsproject.com/kb/virtual-camera-troubleshooting) workaround. Install its provider through OBS once, then keep OBS closed while Edith supplies frames. Disabling Edith stops its capture and frame delivery; Edith never deactivates or removes the separately owned OBS provider. The downloaded package contains a microphone-only carrier using a copy of the same Edith executable, without a camera system extension or special provisioning profiles. OS-managed audio drivers require their own retirement proof. Approval or restart-required results must not be counted as successful retirement. Removing a meeting-microphone HAL driver from disk can leave its loaded code owned by macOS until restart. The extension must retain recoverable ownership and report a restart requirement until retirement completes. Synthetic lifecycle tests must not activate actual system extensions, load real audio drivers, or manipulate production services to produce evidence.

After the final builds and independent checks, regenerate the reports:

```sh
make ci-marketplace-host
make ci-extension-workers EXTENSION=--retain-packages
python3 -B scripts/extension-host-size-report.py --baseline local/baseline/current-main-size.json --host-build local/minimal-host/build-metadata.json --output docs/extension-host-rebuild-size-report.json --markdown-output docs/extension-host-rebuild-size-report.md
```

Review the measured package count against the final host index, confirm the source fingerprints are current, and retain the lifecycle, visual, signing, platform-retirement, and publication results separately. Do not claim these outcomes from artifact sizes alone.
