# Lightweight host rebuild measurements

Measured on 2026-10-09. The rebuild is in progress and the PR is not ready to merge. 23 of the 39 indexed features have been migrated to self-contained workers. These measurements describe the current host foundation, not the final shipping app or all extension packages.

The host contains its executable, marketplace runtime, Sparkle updater including its helpers, application icon, extension metadata, and signatures. It contains zero extension payloads. Feature navigation integration, required platform carriers, the remaining feature migrations, and shipping release packaging still need completion and measurement.

| Measured build | Installed MB | Comparison ZIP MB |
| --- | ---: | ---: |
| Current main with bundled extensions | 131.61 | 59.30 |
| Current host foundation with updater and shared UI | 4.84 | 2.13 |
| Host plus all 23 migrated extensions | 66.52 | 27.45 |

MB means 1,000,000 bytes. The current host foundation is 96.32% smaller on disk than the current-main bundled app. That percentage will be recalculated after the remaining shipping components are integrated. Comparison ZIPs use deflate level 9 over regular files and exclude symlinks. They are a controlled comparison, not shipping installer sizes.

| Independent release package | ZIP bytes | Installed bytes | Release metadata bytes |
| --- | ---: | ---: | ---: |
| Updates | 974,045 | 2,259,839 | 528 |
| BlitzTree | 771,051 | 1,834,498 | 513 |
| Calendar | 788,501 | 1,852,639 | 510 |
| Cleaner | 807,875 | 1,901,596 | 507 |
| Clipboard | 1,039,661 | 2,367,477 | 514 |
| Color Picker | 713,734 | 1,716,107 | 519 |
| Documents | 2,077,920 | 5,811,483 | 499 |
| Emoji Picker | 855,905 | 2,112,833 | 501 |
| Focus Dim | 695,699 | 1,683,394 | 510 |
| Packages | 770,684 | 1,817,647 | 510 |
| Jev | 787,802 | 1,870,352 | 495 |
| Keep Awake | 319,450 | 774,389 | 512 |
| Keystroke Highlight | 719,533 | 1,736,144 | 540 |
| LaTeX | 1,166,967 | 2,886,037 | 502 |
| Mic Mute | 701,491 | 1,699,759 | 507 |
| Music | 5,951,538 | 14,515,248 | 503 |
| Notch Shelf | 1,148,658 | 2,587,768 | 517 |
| Plugins | 1,178,101 | 3,088,055 | 508 |
| Presenter | 733,586 | 1,750,437 | 513 |
| System | 745,068 | 1,782,985 | 504 |
| CPU & Memory in menu bar | 696,862 | 1,683,531 | 519 |
| Screen Recorder | 913,163 | 2,129,394 | 513 |
| Window Sweaters | 766,122 | 1,822,130 | 528 |
| All 23 migrated packages | 25,323,416 | 61,683,742 | 11,772 |

The 23 ZIPs plus their metadata occupy 25,335,188 bytes as release assets. A shared signed catalog, checksums, retained older releases, and packages that have not been migrated are outside this subtotal. These are locally built development artifacts; these particular releases have not been published.

Each enabled extension runs in a worker launched from the same Edith executable. Disabling waits for that process to exit, including a forced shutdown when it does not respond. The host also tracks commands launched into their own process groups and stops those groups on disable, crash, or unresponsive shutdown. The lifecycle test confirms that no worker process remains. Removing an extension stops it before deleting its downloaded packages. User preferences remain separate from downloaded code.

Compatible installed extensions survive app updates without downloading them again. Enabled preferences persist, and workers restart when the updated app starts. Extension updates install immutable, verified packages and restart only the affected worker. A failed update attempts to restore the previous working version. Automatic checks run on app startup at most once every eight hours, only when extensions are installed and automatic extension updates are enabled. Users can also check and update manually. Incompatible installed packages are shown as needing a compatible update.

Local `make ci-marketplace-host` verifies worker failure handling, package integrity and signatures, offline catalog behavior, update preferences, restored enabled extensions, and extension behavior. The real-bundle harness opens a native window, installs a newer version while the previous worker is active, replaces that worker, removes the old app, reconstructs persisted sessions and layouts in a replacement app, disables the extension, checks process exit, and removes its payloads. All 23 migrated extensions pass this flow. Visual review of the completed marketplace and cloud release testing remain outstanding.

Home and Notch customization from merged [PR #1010](https://github.com/pulkitxm/edith/pull/1010) is part of this rebuild. The visual editor, shared canvas and shelf controls, host-owned preferences, profiles, undo/redo, tab order, source filters, and read-only worker context are implemented. Native synthetic UI tests verify both editors at compact and regular widths, increased zoom, and light and dark appearance. Calendar supplies real filtered meeting data and validates Join actions in its worker. The native Notch renderer and world-clock controls are implemented. Live-card adapters for remaining extensions still need completion.

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

The Notch browser and camera preview are functions of the Notch package. They do not require Review or Virtual Camera. The Notch renderer runs only while its extension is enabled. External data and actions will cross the worker command boundary as versioned, bounded data; feature models and services stay outside the base app. The existing native runtime tests now also verify that each tested worker reads the same saved Home configuration after replacement and app restart, and that disabling or removing it leaves the layout intact.

Exact byte counts, package checksums, and the host executable checksum are in [the measurement data](extension-host-rebuild-size-report.json). Regenerate both reports after a fresh host build and extension builds:

```sh
make ci-marketplace-host
make ci-extension-workers EXTENSION=--retain-packages
python3 -B scripts/extension-host-size-report.py --baseline local/baseline/current-main-size.json --output docs/extension-host-rebuild-size-report.json --markdown-output docs/extension-host-rebuild-size-report.md
```

The baseline JSON records source commit `91d0e13de56aaf297ad4630d2c36ef124da5bf0c` and the current-main app measurements. The generator verifies each migrated package's ZIP size, SHA-256, expanded bytes, CRC, and current source fingerprint before producing the comparison. Installed sizes exclude filesystem allocation rounding, receipts, caches, user data, and retained versions.
