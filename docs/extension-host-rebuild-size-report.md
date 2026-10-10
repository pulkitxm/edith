# Lightweight host rebuild measurements

Measured from clean `bc66feff460780b624cafc26bfed02a2b29ed9ca`. All 39 current shipping fingerprints remain unchanged at reviewed `aa24af4fb9a521e25a98d925e8f1053ab40d9ff0`. This report covers **all 39 static size artifacts**. Closed lifecycle verification has **37 passes and two pending retries**, whose last observed results failed (Herdr and Quinjet). All 39 native owners passed 232 selected pure/injected methods at the measured source. These tests do not prove managed UI, real providers or hardware. Portable scripts passed 831 tests with 13 skipped at the reviewed shipping-equivalent source. The hosted original UI journey, production HTTPS release checks and notarization remain separate. Local artifacts use ad-hoc development signing.

Measured on 2026-10-10. Source mode: `final`. All 39 indexed features have measured self-contained worker packages. Package coverage describes the measured artifacts. It does not establish merge readiness, lifecycle test results, visual review, production signing, or release publication.

| Measured build | Installed MB | Comparison ZIP MB |
| --- | ---: | ---: |
| Recorded bundled-app baseline | 131.61 | 59.30 |
| Measured host without extension packages | 8.85 | 4.60 |
| Host plus all 39 measured extension packages | 960.78 | 473.54 |

MB means 1,000,000 bytes. The measured host is 93.28% smaller on disk than the recorded bundled-app baseline. Comparison ZIPs use deflate level 9 over regular files and exclude symlinks. They are controlled comparison archives, not shipping installer sizes. The combined total counts the host and one installed package version per measured feature. OS-managed deployment copies, filesystem allocation rounding, receipts, caches, user data, and retained versions are excluded.

Baseline build: source commit: `91d0e13de56aaf297ad4630d2c36ef124da5bf0c`; configuration: `Release`; architecture: `arm64`; signing: `ad-hoc`; Xcode: `27.0 (27A266a)`; SDK: `27.0`; Ghostty source commit: `88f57ee66eeaad4da77b414b245f7b6693348985`; Ghostty archive: `verified cache from clean pinned source build`.

Host build: source commit: `bc66feff460780b624cafc26bfed02a2b29ed9ca`; uncommitted source changes: `False`; configuration: `Release`; optimization: `Osize`; link-time optimization: `full`; architecture: `arm64`; signing: `ad-hoc`; Xcode: `Xcode 27.0 (27A266a)`; SDK: `27.0`.

| Empty host component | Installed bytes |
| --- | ---: |
| Host and CLI | 6,963,056 |
| Sparkle app updater | 1,441,041 |
| Icons, index and launcher resource | 434,809 |
| Bundle metadata and signatures | 6,482 |
| Total empty host | 8,845,388 |

The host contains the marketplace, window and surface layout controls, worker lifecycle and command gateway. Sparkle updates the application independently of extension updates. Downloaded feature code and resources belong to the packages below. Component sizes count each regular file once and exclude symbolic links.

| Example selection | Downloaded extensions | App plus installed packages MB | Extension download MB |
| --- | --- | ---: | ---: |
| Daily tools | calendar, clipboard, systemStats, usage | 90.21 | 41.09 |
| Development tools | terminal, database, docs, codeStats | 137.21 | 60.44 |
| Media tools | virtualCamera, studio, audioMixer, music, timeLapse | 170.50 | 78.50 |

These selections are size examples, not bundles or defaults. Each feature is downloaded separately. Installing every feature can cost more than the bundled app because independent packages duplicate shared runtime code and native libraries. The empty app and selected-package totals show the savings for people who install only the features they use.

| Local extension artifact | ZIP bytes | Installed package bytes | Package metadata bytes |
| --- | ---: | ---: | ---: |
| Updates | 9,997,576 | 19,718,197 | 536 |
| Attention | 11,989,411 | 24,624,632 | 522 |
| Audio Mixer | 9,666,170 | 19,044,501 | 524 |
| Bifrost | 9,958,852 | 19,651,202 | 515 |
| BlitzTree | 9,300,527 | 18,177,428 | 521 |
| Calendar | 9,807,714 | 19,313,039 | 518 |
| Cleaner | 9,759,202 | 19,228,648 | 515 |
| Clipboard | 10,014,580 | 19,723,599 | 522 |
| Code Stats | 10,418,943 | 20,562,564 | 522 |
| Color Picker | 9,693,344 | 19,094,865 | 527 |
| Memory | 10,879,296 | 21,601,268 | 522 |
| Database | 21,217,242 | 47,626,656 | 519 |
| Documents | 10,630,217 | 21,738,361 | 507 |
| Downloads | 9,901,614 | 19,546,084 | 521 |
| Emoji Picker | 9,821,917 | 19,472,162 | 509 |
| Focus Dim | 9,264,420 | 18,110,570 | 518 |
| Sessions | 20,974,619 | 44,625,524 | 510 |
| Packages | 9,743,101 | 19,194,881 | 518 |
| Jev | 9,725,931 | 19,163,780 | 503 |
| Keep Awake | 9,247,745 | 18,075,840 | 521 |
| Keystroke Highlight | 9,287,625 | 18,146,326 | 548 |
| LaTeX | 10,162,505 | 20,298,033 | 510 |
| Lid Awake | 9,751,328 | 19,250,939 | 518 |
| Machines | 21,181,604 | 45,131,441 | 519 |
| Mic Mute | 9,267,665 | 18,110,404 | 515 |
| Music | 15,341,428 | 32,720,684 | 510 |
| Notch Shelf | 10,541,761 | 20,811,180 | 525 |
| Plugins | 10,153,179 | 20,446,572 | 516 |
| Presenter | 9,704,460 | 19,112,109 | 521 |
| Review | 19,407,479 | 41,555,272 | 516 |
| Site Audit | 10,159,962 | 20,046,411 | 519 |
| Studio | 16,673,935 | 33,489,430 | 513 |
| System | 9,706,685 | 19,128,383 | 512 |
| CPU & Memory in menu bar | 9,728,647 | 19,163,297 | 527 |
| Terminal | 18,170,091 | 38,432,377 | 519 |
| Screen Recorder | 9,467,896 | 18,521,252 | 521 |
| Usage | 11,539,721 | 23,168,170 | 510 |
| Virtual Camera | 27,350,658 | 57,880,253 | 534 |
| Window Sweaters | 9,329,651 | 18,232,284 | 536 |
| All 39 measured packages | 468,938,701 | 951,938,618 | 20,259 |

The 39 local ZIPs plus their JSON metadata occupy 468,958,960 bytes. This subtotal does not include a shared signed catalog, detached checksums, older releases, or unmeasured packages. Measuring local artifacts neither publishes them nor proves that corresponding remote release assets exist. Publication status is not verified by this report.

The generator verifies each package's ZIP size, SHA-256, expanded bytes and CRC. The generator also matched each package's current source fingerprint. The recorded host executable checksum identifies the exact measured binary. Final reports bind sealed carrier metadata and signature-independent executable code to that frozen host and preserve each current package source fingerprint. Re-signed copies retain their actual signed checksums and expanded byte counts; these copies are already included in package totals. The size calculation does not verify code signatures, the host dependency boundary, zero feature payload, lifecycle behavior, card adapters, platform installation, or cloud release behavior. Record those results separately from the measurement.

Worker lifecycle verification covers the owning Edith worker, admitted same-host native tasks, and registered command or descendant process groups. Process-group teardown uses live kernel birth identities. Arbitrarily detached, unregistered feature processes are outside this ownership contract. Camera uses an independently installed OBS Virtual Camera provider, which Edith does not install, remove, or deactivate. Disabling Camera stops its capture and frame delivery. The optional meeting-microphone driver has separate retirement rules and can require a macOS restart. Approval or restart-required retirement must remain visible and keep ownership recoverable. A worker reaching zero processes does not prove that an OS-managed provider or loaded driver has retired.

Home and Notch customization from merged [PR #1010](https://github.com/pulkitxm/edith/pull/1010) uses host-owned layouts and a versioned worker boundary. Size measurements do not validate live card data, actions, cancellation, privacy behavior, or visual editor layouts. Editor sample previews are labeled explicitly; live preview queries already running providers. Run and review synthetic lifecycle and visual fixtures separately for the final integrated feature set.

Exact byte counts, package checksums, and the host executable checksum are in [the measurement data](extension-host-rebuild-size-report.json). See [the measurement procedure](extension-host-rebuild-measurements.md) for build provenance, publication limits and platform retirement checks. After building the final integrated host and every indexed package, regenerate both reports:

```sh
make ci-marketplace-host
make ci-extension-workers EXTENSION=--retain-packages
python3 -B scripts/extension-host-size-report.py --source-mode final --expected-source-commit "$(git rev-parse HEAD)" --packages "$FINAL_PACKAGE_DIRECTORY" --baseline local/baseline/current-main-size.json --app "$FINAL_HOST_APP" --host-build "$FINAL_HOST_BUILD_METADATA" --output docs/extension-host-rebuild-size-report.json --markdown-output docs/extension-host-rebuild-size-report.md
```

The baseline source commit is `91d0e13de56aaf297ad4630d2c36ef124da5bf0c`. Use the runner's exact frozen host app, its matching build metadata and its canonical package directory for `FINAL_HOST_APP`, `FINAL_HOST_BUILD_METADATA` and `FINAL_PACKAGE_DIRECTORY`. An independently re-signed shipping clone is a different provenance input. Final reports require an explicit expected source commit, a matching clean checkout and matching clean host build metadata. Host metadata must match the actual executable checksum. Use `--source-mode interim` for partial or historical measurements; missing build provenance remains explicitly unrecorded. The baseline retains its own recorded source commit and configuration. The empty-host limit remains enforced by the build and shipping verifier, independently of this report.
