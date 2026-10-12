# Current empty-app measurement

The empty Edith app measures **9.41 MB installed** and contains **zero extension payload**. This is **92.85% smaller** than the recorded 131.61 MB bundled-app baseline. The controlled comparison ZIP is **4.90 MB**.

Measured on 2026-10-12 from clean source `26a500e0421bf579473149e1fde2232841ff4c33`, using Release, Osize, full link-time optimization, arm64, Xcode 27.0 and macOS SDK 27.0. The actual build has a verified ad-hoc signature. Later source changes and the final shipping signature must be measured again. The app was built without opening it.

| Empty app component | Bytes | MB |
| --- | ---: | ---: |
| Host and CLI | 7,527,136 | 7.53 |
| Sparkle app updater | 1,441,041 | 1.44 |
| Icons, marketplace index and resources | 434,809 | 0.43 |
| Bundle metadata and signatures | 6,418 | 0.01 |
| Total | 9,409,404 | 9.41 |

MB means 1,000,000 bytes. Totals use exact bytes, so rounded component values can differ from the rounded total. The build contains 64 regular files and lists all 39 extensions without including their code or resources.

| Measurement | Bytes | Meaning |
| --- | ---: | --- |
| Installed logical app size | 9,409,404 | Sum of regular-file lengths, excluding symbolic links |
| Allocated regular-file size | 9,551,872 | Filesystem allocation for those files, excluding directory allocation |
| Controlled comparison ZIP | 4,900,836 | Deflate level 9 over regular files, excluding symbolic links |
| Extension payload inside the app | 0 | Verified by the host builder |

Allocated bytes are filesystem accounting, not a measurement of unique physical APFS blocks. The comparison ZIP is not the shipping DMG. Caches, user data, extension packages, retained package versions and OS deployment copies are additional to app size.

## Extension download sizes

All extensions are downloaded separately. The [earlier all-39 size report](extension-host-rebuild-size-report.md) contains individually measured extension downloads and installed package sizes from source `bc66feff460780b624cafc26bfed02a2b29ed9ca`.

| Earlier all-39 measurement | Bytes | MB |
| --- | ---: | ---: |
| Extension ZIP downloads | 468,938,701 | 468.94 |
| Installed extension packages | 951,938,618 | 951.94 |
| JSON metadata and checksum files | 23,353 | 0.02 |
| Complete local extension release assets | 468,962,054 | 468.96 |

These are historical local artifact measurements. They are not current package sizes or verified published GitHub assets. Shared catalogs, retained releases and deployment copies are additional. Independent packages duplicate their signed carrier and some shared libraries, so installing all 39 can occupy more space than the original bundled app. Downloading only selected extensions avoids that cost.

Disabling keeps an installed package on disk. Removing a package is the operation that reclaims its package storage; user data and caches must remain separate and clearly accounted for. This report measures storage and does not establish memory, provider retirement or end-to-end behavior.

The [exact measurement data](extension-marketplace-current-size.json) records source identity, component totals, the measured executable checksum and comparison archive checksum. The [measurement procedure](extension-host-rebuild-measurements.md) describes regeneration for the final clean host and all 39 packages. Final signed downloads and current package totals remain pending verification.
