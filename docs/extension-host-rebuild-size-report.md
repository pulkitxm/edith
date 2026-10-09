# Lightweight host rebuild measurements

Measured on 9 October 2026. The rebuild is in progress and the PR is not ready to merge. Seven of the 38 indexed features have been migrated to self-contained workers. These measurements describe the current host foundation, not the final shipping app or all extension packages.

The host contains its executable, marketplace runtime, Sparkle updater including its helpers, application icon, extension metadata, and signatures. It contains zero extension payloads. Feature navigation integration, required platform carriers, the remaining feature migrations, and shipping release packaging still need completion and measurement.

| Measured build | Installed MB | Comparison ZIP MB |
| --- | ---: | ---: |
| Original bundled app | 116.47 | 52.27 |
| Superseded partial extraction | 95.70 | 44.94 |
| Current host foundation with updater and shared UI | 3.21 | 1.38 |
| Host plus all seven migrated extensions | 6.33 | 2.58 |

MB means 1,000,000 bytes. The current host foundation is 97.24% smaller on disk than the original bundled app. That percentage will be recalculated after the remaining shipping components are integrated. Comparison ZIPs use deflate level 9 over regular files and exclude symlinks. They are a controlled comparison, not shipping installer sizes.

| Independent release package | ZIP bytes | Installed bytes | Release metadata bytes |
| --- | ---: | ---: | ---: |
| Color Picker | 200,061 | 512,459 | 518 |
| Focus Dim | 182,286 | 474,946 | 509 |
| Keep Awake | 18,173 | 79,141 | 510 |
| Keystroke Highlight | 199,904 | 512,496 | 539 |
| Mic Mute | 178,048 | 473,247 | 506 |
| CPU & Memory in menu bar | 168,196 | 455,755 | 518 |
| Window Sweaters | 248,256 | 616,674 | 527 |
| All seven migrated packages | 1,194,924 | 3,124,718 | 3,627 |

The seven ZIPs plus their metadata occupy 1,198,551 bytes as release assets. A shared signed catalog, checksums, retained older releases, and packages that have not been migrated are outside this subtotal. These are locally built development artifacts; these particular releases have not been published.

Each enabled extension runs in a worker launched from the same Edith executable. Disabling waits for that process to exit, including a forced shutdown when it does not respond. Its dedicated process group also stops owned child processes. The lifecycle test confirms that no worker process remains. Removing an extension stops it before deleting its downloaded packages. User preferences remain separate from downloaded code.

Compatible installed extensions survive app updates without downloading them again. Enabled preferences persist, and workers restart when the updated app starts. Extension updates install immutable, verified packages and restart only the affected worker. A failed update attempts to restore the previous working version. Automatic checks run on app startup at most once every eight hours, only when extensions are installed and automatic extension updates are enabled. Users can also check and update manually. Incompatible installed packages are shown as needing a compatible update.

Local `make ci-marketplace-host` verifies worker failure handling, package integrity and signatures, offline catalog behavior, update preferences, restored enabled extensions, and extension behavior. The real-bundle harness opens a native window, installs a newer version while the previous worker is active, replaces that worker, simulates an app restart, disables the extension, checks process exit, and removes its payloads. All seven migrated extensions pass this flow. Visual review of the completed marketplace and cloud release testing remain outstanding.

Exact byte counts, package checksums, and the host executable checksum are in [the measurement data](extension-host-rebuild-size-report.json). Regenerate it after a fresh host build and extension builds:

```sh
make ci-marketplace-host
make extension-dev EXTENSION=keepAwake
make extension-dev EXTENSION=focusDim
make extension-dev EXTENSION=windowSweaters
make extension-dev EXTENSION=colorPicker
make extension-dev EXTENSION=keystrokeHighlight
make extension-dev EXTENSION=micMute
make extension-dev EXTENSION=systemStats
python3 -B scripts/extension-host-size-report.py --baseline local/baseline/size.json --output docs/extension-host-rebuild-size-report.json
```

The baseline JSON records source commit `9c6b7ae8a4827578c99dbe5a3df433a19293311b` and the original app measurements. The generator verifies each migrated package's ZIP size, SHA-256, expanded bytes, and CRC before producing the comparison. Installed sizes exclude filesystem allocation rounding, receipts, caches, user data, and retained versions.
