# Extension marketplace

Edith ships the app shell, marketplace, settings and Home and Notch layout controls. Its 39 optional extensions download separately from GitHub Releases. An extension uses internal workers from the same Edith executable; users do not install a separate executable.

## Choose a workflow

Onboarding lives inside the app. Choose Agentic, Creative, Developer, Essentials or Custom, then review the individual extensions, versions, download bytes and installed package bytes. Suggestions are editable. Dependencies count once, and packages already installed are excluded from the new-download estimate. Unknown package sizes prevent installation until a compatible verified catalog is available. If a reviewed package changes, the app asks for a new review before downloading it.

The Extensions page supports search, categories, individual downloads and enable controls. Downloading, enabling and removing are separate actions. Undownloaded extension pages stay out of navigation. Downloaded extensions retain their original pages and controls. Home and Notch layouts belong to the app; extension cards follow installed and active provider availability. Disabling a provider makes its live cards inactive while retaining the saved layout.

## App and extension updates

Sparkle updates the app bundle. Extension updates use the signed marketplace catalog and independent package releases. Updating the app preserves downloaded packages and extension user data. Selection checks the package ABI, architecture and minimum macOS version before loading code. An incompatible package stays inactive until a compatible replacement is available. The `minimumSystemVersion` field is a canonical `major.minor.patch` string in the definition, catalog record and sealed payload manifest, and all three must agree. Admission compares the full running system version numerically. AudioMixer requires `14.4.0`, so macOS 14.0 through 14.3 cannot install or start it.

The app fetches the signed catalog at startup and when the Extensions page opens if no catalog is cached or the last successful refresh is more than eight hours old, whether or not any extension is installed.

Upgrading from a release that bundled every feature restores nothing silently. On the first launch of the new app, when no extension has been downloaded yet, Edith reads the abilities that were enabled in the previous release and opens onboarding at the review step with those extensions preselected. The review shows versions and sizes from the signed catalog, and nothing downloads until it is confirmed. This runs once. The production app also stops the previous release's background agent and menu bar helper. The previous lid-awake daemon runs as root, so if it left lid-close sleep disabled, restore Lid Awake and turn it off, or run `sudo pmset -a disablesleep 0`.

Automatic extension updates are enabled by default and can be turned off on the Extensions page. At app startup, an enabled automatic check runs when installed packages exist and at least eight hours have passed since the last successful check. Check for Updates refreshes the catalog on demand. Only downloaded extensions with an available compatible update are updated automatically.

Downloads are verified before they replace installed state. An active version keeps its lease until owned work drains. An unsuccessful replacement preserves the previous usable version when available. Pruning retains rollback and versions still in use. Interrupted removal is recorded and completed on a later launch after those leases are gone. A verified cached catalog and installed packages remain usable offline; an offline cache does not establish that a new download is available.

## Disable, remove and inspect storage

Disabling stops an extension's owned worker, native tasks, commands and registered descendants. It keeps the downloaded package on disk. Pending cleanup remains visible until exit is confirmed. Removing first disables the extension, then removes its package files when they are no longer in use. Removal retains extension user data, including agentic usage history.

Storage shows actual file measurements separately from signed catalog download estimates. It includes the app, package versions, repeated carrier and worker executables, packaged frameworks, owned user data, retained storage and known caches or deployment copies. Removal is available per extension. Files awaiting removal continue to count.

Logical bytes describe file contents; allocated bytes describe filesystem blocks. Hard links count once. APFS clones, compression and shared extents can make exclusive physical usage differ. The scan displays its time, issues and known-root exclusions. It does not promise to measure arbitrary external models, provider storage or every operating-system cache.

Camera uses the separately installed OBS Virtual Camera provider. Disabling Edith stops capture and frame delivery; it does not remove the OBS provider. A separately loaded audio driver can require a macOS restart for retirement, which remains visible instead of being reported as completed cleanup.

## Separate, selective releases

Each extension release contains its ZIP, JSON package metadata and detached checksum. A signed shared catalog points to immutable release assets. Package verification checks the expected publisher, package identity, archive boundaries, checksum and compatibility before installation. Catalog signatures and revision checks prevent untrusted catalogs and rollback from replacing a verified cache.

Production planning fingerprints each extension's production inputs, scoped support libraries, relevant worker contracts and dependencies. A change rebuilds the affected extensions and their dependents. Test-only edits do not change shipping fingerprints. Shared runtime or ABI changes can correctly rebuild several or all packages. Extension releases remain separate from the app release, and the app release waits for a compatible published catalog before advertising the new host.

Native builds, closed worker lifecycle checks and package verification gate publication. Build jobs can run alongside portable tests, but publishing requires those tests to succeed. Resuming an interrupted release verifies existing assets before promotion instead of trusting an unfinished draft.

## Size comparisons and verification scope

The [extension size report](extension-size-report.md) lists each of the 39 measured ZIP and expanded package sizes. The [host rebuild report](extension-host-rebuild-size-report.md) includes the empty app, baseline, component breakdown and example selections. Each report identifies its exact measured source, toolchain, signing mode and verification scope. Historical measurements remain historical until the complete current artifact set is available.

Installing every extension can use more disk space than the former bundled app because independently installed packages contain repeated runtime code and native dependencies. The benefit comes from the small empty app and choosing only the extensions needed. Comparison ZIP sizes are separate from actual shipping DMG sizes, retained releases, user data and operating-system deployment copies.

[The measurement procedure](extension-host-rebuild-measurements.md) describes the source and artifact checks needed to regenerate the reports. Native unit tests, closed worker lifecycle checks, original-view tests, user journeys and public release verification cover different behavior. A passing size calculation or synthetic view fixture does not establish real hardware or external provider behavior.
