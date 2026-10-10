# Lightweight host rebuild measurements

The final all39 package report is pending. The latest controlled host measurement below is an intermediate build, not the shipping app. The PR is not ready to merge.

| Controlled measurement | Installed bytes | Comparison ZIP bytes |
| --- | ---: | ---: |
| Bundled baseline at `91d0e13de56aaf297ad4630d2c36ef124da5bf0c` | 131,607,239 | 59,298,754 |
| Intermediate empty host at `55af74b29bf663ccb545c28e30041784381af178` | 8,178,936 | Not measured |
| Final shipping host | Pending | Pending |
| All39 final extension release assets | Pending | Pending |

The intermediate host contains zero extension payload. It is 93.79% smaller in logical installed bytes than the controlled bundled baseline. Both builds use arm64 Release configuration and development signatures. MB means 1,000,000 bytes. These measurements do not include user data, cache, retained extension versions, filesystem allocation, or a shipping DMG.

| Intermediate host component | Logical bytes |
| --- | ---: |
| Host executable | 6,296,576 |
| Sparkle updater and helpers | 1,441,041 |
| Application icon | 209,225 |
| Compressed marketplace artwork | 220,928 |
| Metadata, resources and signatures | 11,166 |
| Total | 8,178,936 |

This intermediate host exceeded the earlier 8 MB build guard. The accepted empty-host budget is now10 MB, with the full original controls preserved. Compiler and editor experiments saved at most74,336 bytes and did not meet the guard; those changes were not adopted. Restoring original controls and integrating command routing can change the final size further. Removing extension implementations does not remove the app's shared navigation, settings, marketplace, customization editors, updater or worker transport.

The final extension report must count each actual ZIP, JSON release record, checksum and catalog asset. Expanded package sizes must include the complete signed carrier and every copy of the shared host executable. Installing all packages may use more disk space than the original bundled app. No aggregate saving is claimed before all39 current packages are built and verified. Historical packages below do not qualify as final artifacts.

Background lifecycle tests validate install, update, restoration, disable and removal without opening the app. These tests do not establish managed native view behavior. The separate disposable hosted native UI probe is still outstanding. Music inert fixtures decline feature commands, and Studio inert fixtures validate static metadata only; neither is media feature coverage.

## Historical foundation snapshot

Measured on 2026-10-09. This superseded snapshot covers23 historical packages and a smaller host foundation. It does not describe the current source, final shipping app or all39 packages.

The host contains its executable, marketplace runtime, Sparkle updater including its helpers, application icon, extension metadata, and signatures. It contains zero extension payloads. Feature navigation integration, required platform carriers, the remaining feature migrations, and shipping release packaging still need completion and measurement.

| Measured build | Installed MB | Comparison ZIP MB |
| --- | ---: | ---: |
| Bundled baseline at91d0e13 | 131.61 | 59.30 |
| Historical host foundation with updater and shared UI | 4.84 | 2.13 |
| Host plus all 23 migrated extensions | 66.52 | 27.45 |

MB means 1,000,000 bytes. The historical host foundation was 96.32% smaller in logical file bytes than the bundled baseline. That percentage will be recalculated after the remaining shipping components are integrated. Comparison ZIPs use deflate level 9 over regular files and exclude symlinks. They are a controlled comparison, not shipping installer sizes.

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

The historical lifecycle results are superseded by the corrected headless harness. Native-window and managed-view success must not be inferred from this snapshot. Current final-source lifecycle, visual verification and cloud release testing remain outstanding.

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

The baseline JSON records source commit `91d0e13de56aaf297ad4630d2c36ef124da5bf0c` and the controlled bundled app measurements. The generator verifies each migrated package's ZIP size, SHA-256, expanded bytes, CRC, and current source fingerprint before producing the comparison. Installed sizes exclude filesystem allocation rounding, receipts, caches, user data, and retained versions.
