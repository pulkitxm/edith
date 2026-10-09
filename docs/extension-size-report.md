# Extension marketplace size report

This report records the superseded partial extraction. The architecture is being rebuilt around a lightweight host and self-contained workers. See [the current rebuild measurements](extension-host-rebuild-size-report.md) for its measured size and remaining work.

Measured on 9 October 2026. MB means 1,000,000 bytes. These are measurements of the nine packages currently extracted in this PR. The remaining extension implementations still need extraction. Audio Mixer currently downloads its native voice inference backend; its interface and other audio code remain in the app.

## App comparison

| Installation | Installed MB | Comparison download MB |
| --- | ---: | ---: |
| Original bundled app | 116.47 | 52.27 |
| Current app, no downloaded packages | 95.70 | 44.94 |
| Current app with Keep Awake | 95.79 | 44.96 |
| Current app with all eight helper packages, without voice inference | 96.65 | 45.17 |
| Current app with all nine packages | 117.49 | 52.53 |

The app alone saves **20,769,187 installed bytes, or 17.83%**, and **7,329,621 comparison ZIP bytes, or 14.02%**. Installing everything is about 1.03 MB larger than the original app. The marketplace saves space when users install only the features they need. This app is currently about 95.70 MB; it has not become negligible in size.

The app download column is a controlled ZIP comparison, not a shipping DMG size. Both app bundles were measured with the same method: ZIP deflate level 9 over regular files, excluding symlinks. Combined download totals add the individual extension ZIPs to that comparison archive. Installed totals count logical file bytes, not filesystem block allocation.

## Individual packages

| Package | ZIP download bytes | Installed bytes |
| --- | ---: | ---: |
| Audio Mixer voice inference | 7,354,560 | 20,838,072 |
| Color Picker | 14,589 | 95,597 |
| Focus Dim | 25,410 | 116,564 |
| Keep Awake | 13,873 | 93,671 |
| Keystroke Highlight | 33,043 | 124,052 |
| Mic Mute | 22,382 | 98,801 |
| Presenter | 40,477 | 136,023 |
| System Stats | 35,217 | 139,069 |
| Window Sweaters | 48,057 | 152,454 |
| **Total** | **7,587,608** | **21,794,303** |

Each independent extension release contains its ZIP and a JSON record. The nine JSON records add 4,801 bytes, bringing the measured extension release assets to **7,592,409 bytes, or 7.59 MB** per complete set of these versions. The shared signed catalog is additional, small metadata. Historical versions accumulate additional release storage. Unchanged packages reuse their existing releases.

These ZIPs are the actual ad-hoc signed artifacts from the passing [extension CI run](https://github.com/pulkitxm/edith/actions/runs/37842032187). They have not been presented as production releases. Production certificate signatures and subsequent compiler versions can change the sizes slightly. Each ZIP's length, SHA-256, CRC and uncompressed file lengths were checked against its release record.

GitHub permits up to 1,000 assets per release, with each file below 2 GiB, and documents no total release-size or bandwidth limit. These packages are comfortably below those limits. See [GitHub's release storage documentation](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).

## Disk space and disabled extensions

An extension that has never been downloaded consumes no package storage. Disabling an installed extension stops its feature work and retains its files. Remove deletes those files; removal of code loaded in a running process is deferred until that process restarts. Native code can remain mapped in memory until restart, so disabling a previously loaded extension does not guarantee zero memory or zero retained runtime resources.

The tables include one version per package. Receipts, caches, downloaded models, user data and retained older versions are excluded. Updates to loaded extensions stage another version and require a restart before activation. Older versions are currently retained, so repeated updates and host ABI changes can use more disk space than the totals above. An automatic cleanup policy remains outstanding.

The packages are native bundles loaded inside Edith's existing processes. They do not introduce a separate executable service for each extension.

## Release and update behavior

Extension-only source changes rebuild the affected package and declared dependents. Shared host source changes conservatively change the compatibility identifier and rebuild compatible packages. Each changed package gets an immutable release; unchanged packages remain referenced by the signed catalog. The app release waits for a trusted catalog containing packages matching its host compatibility identifier.

Installed, enabled extensions can update automatically on launch when the setting is enabled. Users can also check and install updates from the marketplace. Disabled extensions are not automatically updated. Installed packages remain available offline. If the app's compatibility identifier changes, it needs a compatible package rather than loading an incompatible previous one.

## Verification and reproduction

The fresh release app built successfully and passed `make verify-bundle`, including nested code signatures and framework layout. All twelve installer tests passed after replacing the obsolete inference-library fixture dependency with the marketplace runtime. Eight size-report regression tests cover symlinks, missing apps and packages, duplicate versions, changed archives, incorrect installed sizes and combined totals. The original baseline was remeasured and reproduced exactly.

The app baseline is commit `9c6b7ae8a4827578c99dbe5a3df433a19293311b`. The current app is commit `3027ca05b00bcccb004cf4513a38a093b53669e8`, built for arm64 with release optimizations and development signing. The packages come from the CI run linked above. Exact measurements and package hashes are in [extension-size-report.json](extension-size-report.json).

Given the retained baseline measurement, the built app and the downloaded extension CI artifacts, run:

```sh
python3 -B scripts/extension-size-report.py \
  --baseline local/baseline/size.json \
  --app dist/Edith.app \
  --packages local/ci-extension-packages \
  --source-commit 3027ca05b00bcccb004cf4513a38a093b53669e8 \
  --package-source https://github.com/pulkitxm/edith/actions/runs/37842032187 \
  --output docs/extension-size-report.json
```

The baseline JSON contains `installedBytes`, `zipBytes` and `sourceCommit`. Regenerating the original baseline requires building the baseline commit with the same release configuration and measuring it with `measure_app` in the report script. Local build artifacts are intentionally excluded from version control.
