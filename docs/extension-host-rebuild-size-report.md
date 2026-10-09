# Lightweight host rebuild measurements

Measured on 2026-10-09. The rebuild is in progress and the PR is not ready to merge. 17 of the 39 indexed features have been migrated to self-contained workers. These measurements describe the current host foundation, not the final shipping app or all extension packages.

The host contains its executable, marketplace runtime, Sparkle updater including its helpers, application icon, extension metadata, and signatures. It contains zero extension payloads. Feature navigation integration, required platform carriers, the remaining feature migrations, and shipping release packaging still need completion and measurement.

| Measured build | Installed MB | Comparison ZIP MB |
| --- | ---: | ---: |
| Original bundled app | 116.47 | 52.27 |
| Superseded partial extraction | 95.70 | 44.94 |
| Current host foundation with updater and shared UI | 4.84 | 2.07 |
| Host plus all 17 migrated extensions | 28.37 | 11.92 |

MB means 1,000,000 bytes. The current host foundation is 95.84% smaller on disk than the original bundled app. That percentage will be recalculated after the remaining shipping components are integrated. Comparison ZIPs use deflate level 9 over regular files and exclude symlinks. They are a controlled comparison, not shipping installer sizes.

| Independent release package | ZIP bytes | Installed bytes | Release metadata bytes |
| --- | ---: | ---: | ---: |
| Updates | 815,775 | 1,880,479 | 528 |
| BlitzTree | 612,159 | 1,455,202 | 513 |
| Calendar | 623,850 | 1,456,431 | 510 |
| Cleaner | 649,818 | 1,523,116 | 507 |
| Color Picker | 545,748 | 1,319,883 | 519 |
| Emoji Picker | 688,414 | 1,733,313 | 501 |
| Focus Dim | 529,118 | 1,286,402 | 510 |
| Packages | 615,762 | 1,454,783 | 510 |
| Jev | 631,688 | 1,506,688 | 495 |
| Keep Awake | 18,173 | 79,141 | 510 |
| Keystroke Highlight | 553,523 | 1,323,904 | 540 |
| Mic Mute | 534,091 | 1,286,303 | 507 |
| Presenter | 566,438 | 1,354,469 | 513 |
| System | 588,148 | 1,402,921 | 504 |
| CPU & Memory in menu bar | 528,643 | 1,285,867 | 519 |
| Screen Recorder | 752,077 | 1,750,098 | 513 |
| Window Sweaters | 599,529 | 1,427,090 | 528 |
| All 17 migrated packages | 9,852,954 | 23,526,090 | 8,727 |

The 17 ZIPs plus their metadata occupy 9,861,681 bytes as release assets. A shared signed catalog, checksums, retained older releases, and packages that have not been migrated are outside this subtotal. These are locally built development artifacts; these particular releases have not been published.

Each enabled extension runs in a worker launched from the same Edith executable. Disabling waits for that process to exit, including a forced shutdown when it does not respond. The host also tracks commands launched into their own process groups and stops those groups on disable, crash, or unresponsive shutdown. The lifecycle test confirms that no worker process remains. Removing an extension stops it before deleting its downloaded packages. User preferences remain separate from downloaded code.

Compatible installed extensions survive app updates without downloading them again. Enabled preferences persist, and workers restart when the updated app starts. Extension updates install immutable, verified packages and restart only the affected worker. A failed update attempts to restore the previous working version. Automatic checks run on app startup at most once every eight hours, only when extensions are installed and automatic extension updates are enabled. Users can also check and update manually. Incompatible installed packages are shown as needing a compatible update.

Local `make ci-marketplace-host` verifies worker failure handling, package integrity and signatures, offline catalog behavior, update preferences, restored enabled extensions, and extension behavior. The real-bundle harness opens a native window, installs a newer version while the previous worker is active, replaces that worker, simulates an app restart, disables the extension, checks process exit, and removes its payloads. All 17 migrated extensions pass this flow. Visual review of the completed marketplace and cloud release testing remain outstanding.

Home and Notch customization from merged [PR #1010](https://github.com/pulkitxm/edith/pull/1010) is part of this rebuild. The visual editor, shared canvas and shelf controls, host-owned preferences, profiles, undo/redo, tab order, source filters, and read-only worker context are implemented. Native synthetic UI tests verify both editors at compact and regular widths, increased zoom, and light and dark appearance. Calendar supplies real filtered meeting data and validates Join actions in its worker. The remaining live-card adapters, full world-clock controls, and the Notch worker are still being migrated.

A card is active only when its provider is installed, compatible, and running. Downloaded or remembered-enabled extensions do not count as running. Runtime layouts omit inactive cards without changing the saved configuration. Disabled, removed, or temporarily incompatible extensions retain their positions, filters, and profiles for later restoration. The availability planner returns no provider queries for hidden surfaces and hidden cards. A widget cannot implicitly start an extension. The shared request client cancels affected requests on disable, removal, or version changes and rejects late replies. Presenter changes clear displayed private card data and pause requests immediately. Editor sample previews are labeled explicitly and do not start workers or fetch data; live preview only queries already running providers.

| Customized content | Planned data and action owner |
| --- | --- |
| World clocks | Lightweight host |
| Usage activity, agent usage, rate limits | Usage extension |
| Live agents and permission approvals | Sessions extension |
| Now playing | Music extension |
| Meetings | Calendar extension |
| Code stats | Code Stats extension |
| Focus timer | Attention extension |
| Databases | Database extension |
| Machines | Machines extension |
| GitHub activity | Review extension |
| Quick actions | Running Keep Awake, Lid Awake, Presenter, System, and Mic Mute extensions |
| Desk tools | Running Clipboard, Color Picker, Emoji Picker, and Bifrost extensions |
| Media tools | Running Screen Recorder, Downloads, Virtual Camera, Music, and Studio extensions |
| Individual extension card | Its own extension worker, covering every indexed extension |
| Notch shell, files, browser, camera preview | Downloadable Notch extension |
| Notch Clipboard and Audio tabs | Their own running extension workers |

The Notch browser and camera preview are functions of the Notch package. They do not require Review or Virtual Camera. The Notch renderer will run only while its extension is enabled. External data and actions will cross the worker command boundary as versioned, bounded data; feature models and services stay outside the base app. The existing native runtime tests now also verify that each tested worker reads the same saved Home configuration after replacement and app restart, and that disabling or removing it leaves the layout intact.

Exact byte counts, package checksums, and the host executable checksum are in [the measurement data](extension-host-rebuild-size-report.json). Regenerate both reports after a fresh host build and extension builds:

```sh
make ci-marketplace-host
make ci-extension-workers EXTENSION=--retain-packages
python3 -B scripts/extension-host-size-report.py --baseline local/baseline/size.json --output docs/extension-host-rebuild-size-report.json --markdown-output docs/extension-host-rebuild-size-report.md
```

The baseline JSON records source commit `9c6b7ae8a4827578c99dbe5a3df433a19293311b` and the original app measurements. The generator verifies each migrated package's ZIP size, SHA-256, expanded bytes, CRC, and current source fingerprint before producing the comparison. Installed sizes exclude filesystem allocation rounding, receipts, caches, user data, and retained versions.
