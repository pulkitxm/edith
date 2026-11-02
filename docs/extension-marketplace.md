# Extension marketplace

Edith ships the app shell, marketplace, settings and Home and Notch layout controls. Optional extensions download separately from GitHub Releases. Each extension loads in process into the single Edith app; users do not install a separate executable.

## Choose a workflow

Onboarding lives inside the app. Choose a group (Agents & Terminal, Mac Utilities, Desk, Media, or Developer & Data) or Custom, then review the individual extensions, versions, download bytes and installed package bytes. Suggestions are editable. Dependencies count once, and packages already installed are excluded from the new-download estimate. Unknown package sizes prevent installation until a compatible verified catalog is available. If a reviewed package changes, the app asks for a new review before downloading it.

The Extensions page groups extensions into those five groups and supports search, individual downloads and enable controls. Experimental extensions (Hinge, Window Sweaters and Jev) live in a Labs group that is hidden from the full list and appears in search or when Labs is selected. Downloading, enabling and removing are separate actions. Undownloaded extension pages stay out of navigation. Downloaded extensions retain their original pages and controls. Home and Notch layouts belong to the app; extension cards follow installed and active provider availability. Disabling a provider makes its live cards inactive while retaining the saved layout.

## App and extension updates

Sparkle updates the app bundle. Extension updates use the signed marketplace catalog and independent package releases. Updating the app preserves downloaded packages and extension user data. Selection checks the package ABI, architecture and minimum macOS version before loading code. An incompatible package stays inactive until a compatible replacement is available. The `minimumSystemVersion` field is a canonical `major.minor.patch` string in the definition, catalog record and sealed payload manifest, and all three must agree. Admission compares the full running system version numerically. AudioMixer requires `14.4.0`, so macOS 14.0 through 14.3 cannot install or start it.

The app fetches the signed catalog at startup and when the Extensions page opens if no catalog is cached or the last successful refresh is more than eight hours old, whether or not any extension is installed.

Upgrading from a release that bundled every feature restores nothing silently. On the first launch of the new app, when no extension has been downloaded yet, Edith reads the abilities that were enabled in the previous release and opens onboarding at the review step with those extensions preselected. The review shows versions and sizes from the signed catalog, and nothing downloads until it is confirmed. This runs once. The production app also stops the previous release's background agent and menu bar helper. The previous lid-awake daemon runs as root, so if it left lid-close sleep disabled, restore Lid Awake and turn it off, or run `sudo pmset -a disablesleep 0`.

Automatic extension updates are enabled by default and can be turned off on the Extensions page. At app startup, an enabled automatic check runs when installed packages exist and at least eight hours have passed since the last successful check. Check for Updates refreshes the catalog on demand. Only downloaded extensions with an available compatible update are updated automatically. A batch uses one verified catalog snapshot. Independent package plans download concurrently; plans that share dependencies run in separate waves so they cannot replace the same package at once.

Downloads are verified before they replace installed state. An active version keeps its lease until owned work drains. An unsuccessful replacement preserves the previous usable version when available. Every package in an installation plan, including dependencies, retains its previous selection until activation succeeds. A dependency activation failure leaves later packages on their previous selections. Pruning retains rollback and versions still in use. Interrupted removal is recorded and completed on a later launch after those leases are gone. Enable intent is saved before startup, so a failed first launch participates in bounded automatic recovery and survives an app restart. Successful recovery clears its startup error. A newly installed Usage extension reports initial collection as pending, keeps its page loading until a validated document is ready, and surfaces collection errors without claiming the extension is disabled. Disabling a failed extension cancels that intent. Cleanup failures remain pending until cleanup succeeds.

A verified cached catalog and installed packages remain usable offline; an offline cache does not establish that a new download is available.

## When extensions start

Extensions that declare `background` work, and extensions whose card is placed on the Home or Notch layout, start when Edith launches; adding a card for an idle extension starts it. Shortcuts declared in `Extensions/<id>/package.json` are registered by the host while their extension is idle, and the first press starts it. The others are on demand: an enabled on-demand extension stays idle at launch, with no code loaded, and starts the first time its page opens or one of its commands runs. Idle extensions appear in the sidebar, Settings and `ed` help like running ones, and `ed extensions ls` reports them as `idle`. Each extension declares `background` in `Extensions/<id>/package.json`.

If Edith quits unexpectedly while extensions are starting, the next launch starts those extensions one at a time after the others. An extension that is starting alone when Edith quits again is turned off and shows why; enabling it again retries.

A full signature check runs the first time a package's exact files are seen. Later launches skip it while every file keeps the same identity, size, modification time and change time.

## Disable, remove and inspect storage

Disabling stops an extension's work, native tasks, commands and registered descendants. Swift code remains mapped until Edith quits, and package versions still in use remain on disk. Each window and card owns its own interface state, so opening or closing another presentation does not reset it. Interface reuse is bound to the selected version and the running engine generation. Restarting an engine at the same version creates a fresh interface, and retired presentations leave the session registry. Pages distinguish startup, disabled state and startup failure, and failed interfaces offer a retry action. Shared interface services stay alive while another window or card uses the same package image. Closing a scene cancels its own requests; shared teardown waits for the final presentation. Pending cleanup remains visible until work has drained. Removing first disables the extension, then removes its package files when they are no longer in use. Removal retains extension user data, including agentic usage history.

Storage shows actual file measurements separately from signed catalog download estimates. It includes the app, package versions, packaged frameworks, owned user data, retained storage and known caches or deployment copies. Removal is available per extension. Files awaiting removal continue to count.

Logical bytes describe file contents; allocated bytes describe filesystem blocks. Hard links count once. APFS clones, compression and shared extents can make exclusive physical usage differ. The scan displays its time, issues and known-root exclusions. It does not promise to measure arbitrary external models, provider storage or every operating-system cache.

Camera uses the separately installed OBS Virtual Camera provider. Disabling Edith stops capture and frame delivery; it does not remove the OBS provider. A separately loaded audio driver can require a macOS restart for retirement, which remains visible instead of being reported as completed cleanup.

## Separate, selective releases

Each extension release contains its ZIP, JSON package metadata and detached checksum. A signed shared catalog points to immutable release assets. Package verification checks the expected publisher, package identity, archive boundaries, checksum and compatibility before installation. Catalog signatures and revision checks prevent untrusted catalogs and rollback from replacing a verified cache.

Production planning fingerprints each extension's production inputs, the shared extension kit, the marketplace runtime and dependencies. A change rebuilds the affected extensions and their dependents. Test-only edits do not change shipping fingerprints. Shared runtime or ABI changes can correctly rebuild several or all packages. Extension packages publish in the same CI run as the app, before it. The app release then checks once that the catalog has a package for every extension on its host contract.

Native builds, package tests and package verification gate publication. Build jobs can run alongside portable tests, but publishing requires those tests to succeed. Resuming an interrupted release verifies existing assets before promotion instead of trusting an unfinished draft.

Installing every extension can use more disk space than the former bundled app because independently installed packages contain repeated native dependencies. The benefit comes from the small empty app and choosing only the extensions needed. A passing package test or synthetic view fixture does not establish real hardware or external provider behavior.
