# Service verification

The service audit runs actual executable processes with synthetic fixtures. Readiness checks establish installation, permissions, configuration, and readable storage. They do not prove that a hardware interaction or an external service action completed.

## Executed daemon flows

The seven fixture suites completed 51 checks successfully. Every fixture launchd service was confirmed stopped afterward. Clipboard verification also confirmed that signing fixture executables left the source build products unchanged.

| Suite | Checks | Verified behavior |
| --- | ---: | --- |
| `test-daemon-e2e.py` | 9 | Client exit, task progress, command failures, cancellation, process restart, persisted results, isolated cloud backup and restore, interrupted downloads |
| `test-clipboard-daemon-e2e.py` | 10 | Stored history, concurrent mutations, safe previews, pinned retention, thumbnails, missing payload detection, disconnected clients, paging beyond 4,096 records, oversized payload preservation |
| `test-attention-daemon-e2e.py` | 7 | Listener startup without either UI, authentication, domain privacy, CLI reads, restart persistence, live configuration changes, favicon caching |
| `test-attention-delivery-e2e.py` | 4 | Durable samples while offline, draining without the helper, replay protection, restart continuity, recovered queue diagnostics |
| `test-site-audit-daemon-e2e.py --lighthouse` | 6 | Real loopback HTTP discovery, partial progress, cancellation, restart recovery, real headless browser scores, project deletion |
| `test-machine-daemon-e2e.py` | 12 | Loopback SSH, binary command IO, atomic transfers, failed publication, streamed metrics, cancellation, remote process cleanup, timeout handling, transfers after client exit |
| `test-development-identity-e2e.py` | 3 | Packaged client authentication, default development service identity, isolated development storage, background work after client exit |

These runs use private settings, storage, credentials, and service names. The cloud backup fixture writes to a local temporary directory. The download fixture uses a local executable stub. The machine fixture uses its own loopback SSH server and disposable keys. Site Audit uses synthetic pages served over loopback HTTP.

After building the executable products, run from the repository root:

```sh
export EDITH_TEST_BUILD_DIR="$PWD/Packages/Edith/.build/arm64-apple-macosx/debug"
python3 -B scripts/test-daemon-e2e.py
python3 -B scripts/test-clipboard-daemon-e2e.py
python3 -B scripts/test-attention-daemon-e2e.py
python3 -B scripts/test-attention-delivery-e2e.py
python3 -B scripts/test-site-audit-daemon-e2e.py --lighthouse
python3 -B scripts/test-machine-daemon-e2e.py
python3 -B scripts/test-development-identity-e2e.py
```

Use the actual build directory for the selected architecture and configuration. Attention delivery requires the built test bundle and its framework dependencies. Packaged identity requires a development application at `dist/Edith.app` and refuses to replace an already registered development daemon. The browser scoring run requires Lighthouse and Chrome. Fixtures print their temporary results directory and return a nonzero status on failure.

## Feature coverage and boundaries

| Surface | Verification layer | Remaining interaction boundary |
| --- | --- | --- |
| Usage | Collector, scheduler, provider, and refresh integration tests | Real provider availability and historical source completeness |
| Sessions | Session parsing and lifecycle readiness tests, including zero sessions with host errors | Starting and attaching an actual session on each remote host |
| Review | Executable and terminal integration readiness | Creating and navigating a review session |
| Memory | Backend health and configuration readiness | Deployed backend, connector ingestion, and retrieval |
| Plugins | Bundled catalog and installation readiness | Installing into each supported application |
| Updates | Inventory and update operation tests | Installing an actual application update |
| Packages | Package manager executable readiness | Installing or removing a real package |
| Cleaner | Scan and operation tests | Reviewing and moving selected real files |
| System | Application inventory and command readiness | Keyboard locking and controlling actual applications |
| Keep Awake | Assertion lifecycle and shared setting integration tests | Sustained physical idle and wake behavior |
| Lid Awake | Service registration and session lifecycle tests | Physical lid closure and power transitions |
| CPU and memory | Actual metric sampling | Long-running menu bar presentation |
| Mic Mute | Input device discovery | Muting and restoring each physical device |
| Clipboard | Ten daemon fixture checks | Foreground paste into another application |
| Emoji | Catalog, search, picker, and operation tests | Foreground insertion into another application |
| Color Picker | Formatting, history, and operation tests | Sampling an actual display |
| Keystroke Highlight | Readiness, lifecycle, and input handling tests | Physical key events and visible overlay |
| Focus Dim | Selection and dimming calculations | Actual display overlays and display hot-plugging |
| Presenter | Protection rules and pause lifecycle tests | Real screen-sharing detection |
| Music | Library and playback operation tests, player status reads | Audible playback and external player control |
| Downloads | Daemon queue restart and child cleanup fixture | A real download from an external media service |
| Notch Shelf | Stored index, thumbnail, and service lifecycle tests | Drag and drop, camera preview, and device detection |
| Audio Mixer | Injected tap lifecycle and gain tests | Actual audio permission and hardware processing |
| Calendar | Permission lifecycle and event reads | External account refresh and calendar changes |
| Database | Broker readiness and adapter tests | Every configured external database and write operation |
| Attention | Seven daemon and four durable-delivery fixture checks | Browser extension activity across supported browsers |
| Site Audit | Six fixture checks including real browser scores | Arbitrary external sites |
| Machines | Twelve loopback SSH fixture checks | Reachability and host-specific configuration of each remote machine |
| Backup | Synthetic backup and restore without the helper | Actual cloud transport and account availability |

The feature table identifies exercised layers and existing test entry points. It does not certify every external integration or hardware action. Disabled, paused, empty, and failed states must remain distinct. A missing clipboard payload cannot be recovered by a readiness check, and preserved oversized records remain subject to the payload retrieval limit.

The packaged development identity run launches only the packaged daemon with a private fixture home and settings. It does not launch or replace the installed application.
