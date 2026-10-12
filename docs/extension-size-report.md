# Extension marketplace size report

Measured from clean `bc66feff460780b624cafc26bfed02a2b29ed9ca`. All 39 shipping fingerprints remain unchanged at reviewed `abe20a7957309e995cd2ee2b32b6d7010c6df300`. This report covers **all 39 static size artifacts**. Closed headless lifecycle verification has **39 distinct owners passed across three qualified sources**: 37 at measured bc66, Quinjet at 46f, and Herdr at abe20. Historical failed attempts remain preserved; the retry artifacts do not retag the measured package tables. All 39 native owners passed 232 selected pure/injected methods at bc66. Portable scripts passed 831 with 13 skipped at `aa24af4fb9a521e25a98d925e8f1053ab40d9ff0`. The separate hosted diagnostic tier at `423c953e06b255d540a35abf5281ed3acbae70c5` passed 711 unique test methods in 720 executions, with zero owned survivors. These results do not prove all original managed views, real providers or hardware. The 13-stage original UI journey, all 39 managed views, production catalog/release verification and notarization remain pending. Current abe20 CI recorded one privileged-process fixture timeout in 718 tests across 122 suites; this report does not claim all CI passed. Local artifacts use ad-hoc development signing.

The actual bc66 local release assets total 468,962,054 bytes: 468,938,701 ZIP bytes, 20,259 JSON metadata bytes and 3,094 checksum-file bytes. Shared signed catalogs, retained releases, caches, user data and OS deployment copies are additional. The separately built current abe20 retry host is 8,845,416 installed bytes, 28 more than the measured host, and its signed executable matches the separate 46f retry host. It differs from the measured bc66 host. Quinjet retry artifacts are 19,407,524 ZIP bytes and 41,555,367 expanded bytes; Herdr retry artifacts are 20,974,663 ZIP bytes and 44,625,619 expanded bytes. These artifacts do not replace or retag the measured bc66 tables or controlled comparison ZIP, and are not production DMG measurements.

The empty host has zero extension payload and indexes 39 features. This replaces the superseded nine-package extraction measurement. The full code provenance and component breakdown are in [the host rebuild report](extension-host-rebuild-size-report.md).

| Measured installation | Installed bytes | Controlled comparison ZIP plus package ZIP bytes |
| --- | ---: | ---: |
| Recorded bundled-app baseline | 131,607,239 | 59,298,754 |
| Empty host | 8,845,388 | 4,598,014 |
| Host with all 39 packages | 960,784,006 | 473,536,715 |

The empty host saves 122,761,851 installed bytes (93.28%) and 54,700,740 comparison ZIP bytes (92.25%). Installing every package uses more space than the bundled baseline because self-contained packages duplicate the host runtime and native dependencies. The 550,100,464 bytes of repeated signed host executables are already included in the expanded package total.

Comparison ZIPs use deflate level 9 over regular files and exclude symlinks. They are controlled comparisons, not shipping DMGs. Installed sizes count logical regular-file bytes for one package version, including packaged native libraries and models. Filesystem allocation rounding, receipts, external caches or models, user data, retained versions and OS-managed deployment copies are excluded. MB means 1,000,000 bytes.

| Package | ZIP download bytes | Expanded package bytes | JSON metadata bytes |
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
| All 39 packages | 468,938,701 | 951,938,618 | 20,259 |

The 39 ZIPs and their JSON metadata total 468,958,960 bytes. Their checksum files add 3,094 bytes, yielding 468,962,054 bytes of complete local release assets. Shared signed catalogs and older releases are additional. These are local development artifacts, not verified published release downloads. Exact archive checksums, byte counts and source fingerprints are in [extension-size-report.json](extension-size-report.json).

The measurement verifies actual ZIP length, SHA256, CRC and expanded bytes for every package. The companion host report also binds copied carrier code to the frozen host while retaining signed, raw unsigned and normalized checksums. The measured Herdr and Quinjet archives have static size and provenance proof; their owners passed separate source-qualified headless retries without replacing these measured archives. The size report neither validates original native UI nor demonstrates production signing or cloud release availability.

An undownloaded extension has no installed package files. Disabling retains those files and requests owned feature work to stop. Pending cleanup keeps ownership visible until confirmed exit; zero owned runtime is verified after that exit. Package removal waits for owned leases and preserves user data. Platform driver retirement is separate from measuring package disk bytes. The 39 source-qualified closed engine fixtures verify their disable, update, restoration and removal assertions with zero disabled owned workers, across the three identified sources. Music and Notch use inert feature-decline and metadata checks; their actual live surface data and all managed original views are outside that headless proof.

The measured baseline is `91d0e13de56aaf297ad4630d2c36ef124da5bf0c`. The measured host is `bc66feff460780b624cafc26bfed02a2b29ed9ca`, arm64 Release with Osize, full LTO, Xcode 27.0 (27A266a), macOS SDK 27.0 and ad-hoc signing. Its executable SHA256 is `d5d3f480ca4930c55069273debbd55e500e4939b5212acd68332ffa9108f0ab1`. Actual postmerge production asset sizes, certificate signatures and notarization results require independent verification.

Regenerate against a clean checkout of the measured source and its exact frozen host, matching build metadata and canonical 39-package directory:

```sh
python3 -B scripts/extension-size-report.py --baseline local/baseline/current-main-size.json --app "$FINAL_HOST_APP" --packages "$FINAL_PACKAGE_DIRECTORY" --source-commit "$MEASURED_SOURCE_COMMIT" --package-source source-bound-local-development-artifacts --output docs/extension-size-report.json
python3 -B scripts/extension-host-size-report.py --source-mode final --expected-source-commit "$MEASURED_SOURCE_COMMIT" --baseline local/baseline/current-main-size.json --app "$FINAL_HOST_APP" --host-build "$FINAL_HOST_BUILD_METADATA" --packages "$FINAL_PACKAGE_DIRECTORY" --output docs/extension-host-rebuild-size-report.json --markdown-output docs/extension-host-rebuild-size-report.md
```

Symbolic paths represent source-bound local artifacts. Final source mode requires clean matching source and host metadata; a later reviewed commit is qualified by actual unchanged shipping fingerprints rather than relabeling older runtime receipts.
