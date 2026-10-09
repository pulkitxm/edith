# Lightweight host rebuild measurements

Measured on 2026-10-09. The rebuild is in progress and the PR is not ready to merge. 14 of the 39 indexed features have been migrated to self-contained workers. These measurements describe the current host foundation, not the final shipping app or all extension packages.

The host contains its executable, marketplace runtime, Sparkle updater including its helpers, application icon, extension metadata, and signatures. It contains zero extension payloads. Feature navigation integration, required platform carriers, the remaining feature migrations, and shipping release packaging still need completion and measurement.

| Measured build | Installed MB | Comparison ZIP MB |
| --- | ---: | ---: |
| Original bundled app | 116.47 | 52.27 |
| Superseded partial extraction | 95.70 | 44.94 |
| Current host foundation with updater and shared UI | 3.66 | 1.57 |
| Host plus all 14 migrated extensions | 16.24 | 6.68 |

MB means 1,000,000 bytes. The current host foundation is 96.86% smaller on disk than the original bundled app. That percentage will be recalculated after the remaining shipping components are integrated. Comparison ZIPs use deflate level 9 over regular files and exclude symlinks. They are a controlled comparison, not shipping installer sizes.

| Independent release package | ZIP bytes | Installed bytes | Release metadata bytes |
| --- | ---: | ---: | ---: |
| Calendar | 409,393 | 983,151 | 509 |
| Color Picker | 347,697 | 864,507 | 518 |
| Emoji Picker | 469,144 | 1,225,185 | 501 |
| Focus Dim | 330,088 | 829,026 | 509 |
| Packages | 409,201 | 981,647 | 509 |
| Jev | 432,399 | 1,035,200 | 495 |
| Keep Awake | 18,173 | 79,141 | 510 |
| Keystroke Highlight | 347,605 | 867,008 | 539 |
| Mic Mute | 326,965 | 828,863 | 506 |
| Presenter | 368,002 | 897,989 | 512 |
| System | 382,324 | 929,849 | 503 |
| CPU & Memory in menu bar | 319,166 | 811,099 | 518 |
| Screen Recorder | 547,446 | 1,277,858 | 513 |
| Window Sweaters | 400,786 | 970,258 | 527 |
| All 14 migrated packages | 5,108,389 | 12,580,781 | 7,169 |

The 14 ZIPs plus their metadata occupy 5,115,558 bytes as release assets. A shared signed catalog, checksums, retained older releases, and packages that have not been migrated are outside this subtotal. These are locally built development artifacts; these particular releases have not been published.

Each enabled extension runs in a worker launched from the same Edith executable. Disabling waits for that process to exit, including a forced shutdown when it does not respond. The host also tracks commands launched into their own process groups and stops those groups on disable, crash, or unresponsive shutdown. The lifecycle test confirms that no worker process remains. Removing an extension stops it before deleting its downloaded packages. User preferences remain separate from downloaded code.

Compatible installed extensions survive app updates without downloading them again. Enabled preferences persist, and workers restart when the updated app starts. Extension updates install immutable, verified packages and restart only the affected worker. A failed update attempts to restore the previous working version. Automatic checks run on app startup at most once every eight hours, only when extensions are installed and automatic extension updates are enabled. Users can also check and update manually. Incompatible installed packages are shown as needing a compatible update.

Local `make ci-marketplace-host` verifies worker failure handling, package integrity and signatures, offline catalog behavior, update preferences, restored enabled extensions, and extension behavior. The real-bundle harness opens a native window, installs a newer version while the previous worker is active, replaces that worker, simulates an app restart, disables the extension, checks process exit, and removes its payloads. All 14 migrated extensions pass this flow. Visual review of the completed marketplace and cloud release testing remain outstanding.

Exact byte counts, package checksums, and the host executable checksum are in [the measurement data](extension-host-rebuild-size-report.json). Regenerate both reports after a fresh host build and extension builds:

```sh
make ci-marketplace-host
make ci-extension-workers EXTENSION=--retain-packages
python3 -B scripts/extension-host-size-report.py --baseline local/baseline/size.json --output docs/extension-host-rebuild-size-report.json --markdown-output docs/extension-host-rebuild-size-report.md
```

The baseline JSON records source commit `9c6b7ae8a4827578c99dbe5a3df433a19293311b` and the original app measurements. The generator verifies each migrated package's ZIP size, SHA-256, expanded bytes, CRC, and current source fingerprint before producing the comparison. Installed sizes exclude filesystem allocation rounding, receipts, caches, user data, and retained versions.
