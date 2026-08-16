# Contributing to Edith

Issues and pull requests are welcome. Bug reports, design feedback,
documentation, tests, and code all help.

## Before You Start

- Search existing issues and pull requests before opening a duplicate.
- Use GitHub Discussions for usage questions and early ideas.
- Open an issue before a substantial feature, privacy change, or architectural change.
- Keep pull requests focused and separate unrelated changes.
- Never include credentials, personal data, private repository contents, usage history, or generated build artifacts.

## Build and run

### macOS

```bash
./build.sh
./build.sh --install
cd Packages/Edith && ./test.sh
```

Needs Xcode, not just Command Line Tools: `edth.xcodeproj` at the repo root
is what assembles the app. `build.sh` drives `xcodebuild` for the `EdithMain`
scheme, which builds and embeds `EdithHelper` (the always-on menu bar
companion, nested at `Contents/Library/LoginItems` and shipped as
`Edith.app`), `EdithFiles` (nested at `Contents/Library/Applications`), and
the `ed`/`edh` CLI tools (`Contents/MacOS`). Its final embed phase also builds
`EdithLidAwakeHelper` with SwiftPM and places the signed executable and launchd
property list inside the menu bar companion.

All Swift code lives in one SwiftPM package, `Packages/Edith`. The Xcode
targets are folder-synchronized onto `Packages/Edith/Sources/*`, so a file
dropped into a target's directory builds with no project file to edit, and
`swift build` and `swift test` work on the same sources without Xcode. Use
`./test.sh` rather than `swift test`; it adds the search paths for the
Testing framework that ships with Command Line Tools.

`build.sh` re-signs the bundle after `xcodebuild` rather than leaving Xcode's
signature in place. Xcode writes a designated requirement that names the
exact leaf certificate, so re-issuing or swapping that certificate (Apple
Development to Developer ID, say) stops it matching and macOS drops every TCC
grant the app had: Screen Recording, Accessibility, Calendar. Pinning the
requirement to bundle id plus team id instead survives all of that. The
identity is `EDITH_SIGN_IDENTITY`, else the first available Developer ID
Application, self-signed `Edith Dev`, or Apple Development certificate, else
ad-hoc. Ad-hoc signatures change on every rebuild, which is what resets those
grants, so for day-to-day work create a self-signed certificate once through
Keychain Access, Certificate Assistant, Create a Certificate, named
"Edith Dev", Identity Type "Self Signed Root", Certificate Type
"Code Signing".

Before it signs a `--release` build, `build.sh` strips the binaries in `dist`.
Xcode's Release configuration builds with `dwarf-with-dsym` and no stripping, and
a plain `xcodebuild build` never strips, so every shipped binary would otherwise
carry its full DWARF. The `.dSYM` bundles stay in `build/Build/Products/Release`,
so a crash report is still symbolicatable.

The Release configuration also pins `ARCHS = arm64`. Xcode's default builds a
universal binary, which doubles every executable in the bundle; the SwiftPM build
this project replaced only ever produced arm64, so the x86_64 slice was never
something Edith shipped deliberately. Together with the stripping that is a 64MB
DMG down to 23MB.

It also deletes the `Frameworks` directory Xcode embeds inside the nested
`Edith Files.app`. That app links Sparkle through the outer bundle, its rpath is
`@executable_path/../../../../../Frameworks`, and `make verify-bundle` asserts
both that exactly one `Sparkle.framework` ships and that the path the rpath
resolves to exists.

The main source tree is organized by role after the feature-folder restructure:

| Path | Responsibility |
| --- | --- |
| `Packages/Edith/Sources/Edith/Core` | App lifecycle, navigation and windows for the main app. |
| `Packages/Edith/Sources/Edith/Features` | Main-app screens, grouped by feature and then model, view model, view or service. |
| `Packages/Edith/Sources/Edith/Shared` | Main-app views shared by more than one feature. |
| `Packages/Edith/Sources/EdithHelper/Core` | Lifecycle, navigation and panel control for the menu bar companion. |
| `Packages/Edith/Sources/EdithHelper/Features` | Always-on macOS integrations and their menu bar UI. |
| `Packages/Edith/Sources/EdithKit/Core` | Shared macOS defaults, IPC, paths, processes, resources and update support. |
| `Packages/Edith/Sources/EdithKit/Features` | Reusable macOS domain models and services. |
| `Packages/Edith/Sources/EdithCore` | Shared extension registry and platform capability models. |

`AppIcon.icns` and the helper's `MenuBar.png` are checked in, generated from
`Packages/Edith/Sources/Edith/Resources/appicon.png`. Run `make icon` after
changing the artwork.

### Companion backend

`apps/companion` is a Rust 2024 Axum service backed by PostgreSQL with pgvector,
Redis, Ollama and Whisper. The app's guided setup packages the runtime files and
deploys the stack to this Mac or a registered SSH machine. It selects the Apple
Metal, GPU or CPU Compose overlay from the host it probes.

For backend-only work, install stable Rust with Clippy and use:

```bash
cd apps/companion
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
```

Migration tests also need a pgvector PostgreSQL 18 instance. CI supplies one and
runs `cargo run --locked -- --migrate-only` with `DATABASE_URL` set. The complete
end-user deployment and data model are in the
[Companion guide](docs/companion.md).

## Checks

Run `make ci` before pushing. The pre-push hook runs the applicable macOS, site,
script and policy gates in parallel. Companion changes have additional commands
below and a dedicated CI job.

| Target | What it does |
| --- | --- |
| `make ci` | All macOS, script, site, and policy checks below, after `bun install --frozen-lockfile`. |
| `make ci-comments` | Fails on any disallowed comment in tracked source. |
| `make ci-secrets` | Scans every tracked file for leaked secrets. |
| `make ci-duplicate-keys` | Fails when a `UserDefaults`/`SharedDefaults` key is spelled out as a raw string literal in more than one Swift file instead of going through one shared constant. |
| `make ci-lint` | Biome format and lint for `scripts/` and `apps/site`. |
| `make ci-scripts` | The `bun test` suite for `scripts/`. |
| `make ci-promo` | `npm ci` and type check for the Remotion promo video. |
| `make ci-swift-lint` | `swift format lint --strict` over `Sources`, `Tests` and `Package.swift`. |
| `make ci-swift-build` | One `xcodebuild` of the `EdithMain` scheme, which builds all five Xcode targets and runs the privileged-helper SwiftPM embed phase. |
| `make ci-swift-test` | The Swift test suite, through `Packages/Edith/test.sh`. |
| `make ci-swift-check` | The three above. They share nothing, so CI and the pre-push hook run them in parallel. |
| `make ci-swift` | `ci-swift-check` plus a full `build.sh` and `make verify-bundle`. |
| `make verify-bundle` | Bundle layout and codesign assertions against `dist/Edith.app`. |

For Companion backend changes, run the Clippy and Cargo tests shown above. CI also
applies every migration to a real
pgvector database. These checks are not part of `make ci` or the pre-push hook.

Other targets: `make build`, `make install`, `make reset`, `make reinstall`,
`make icon`, `make site-dev` (serves `apps/site` on port 8000), `make loc`,
and `make wiki`.

This repo is kept comment-free and CI enforces it. Run `bun run strip-comments`
if one slips in. Write names and structure that do not need prose.

## Pull Requests

A pull request description is one line that states what changed and why. Use
checkpoint commits for logical changes, add tests for changed behavior, and run
the relevant checks before requesting review. After verification is complete,
post one short evidence comment that shows the end result through a screenshot,
recording, or clean terminal output when the change has something meaningful to
demonstrate.

Maintainers may request changes before merge. By contributing, you agree that
your contribution is licensed under the repository's GNU General Public License
v3.0.

## Reporting Security Issues

Do not publish exploitable security issues in a public issue. Follow
[SECURITY.md](SECURITY.md) and use GitHub's private vulnerability reporting
form instead.

## Releases

Merging application changes into `main` publishes a new patch version after the
required CI jobs pass. CI calls the reusable release workflow, which builds the
signed DMG, notarizes it when Apple credentials are available, generates the signed
Sparkle appcast, then publishes both assets to one GitHub Release. The versioned
plists and cask land together in one release commit
and tag, and the cask is mirrored to the tap. To rebuild an existing release, run
the Release workflow manually from `main` with its required `rebuild` input set to
the current tag. Only the current release can be rebuilt. The rebuild replaces its
two assets, commits a changed DMG checksum to `main` when needed, and mirrors the
same cask to the tap. It does not create a new version or tag. To recover a skipped
automatic release, run the CI workflow manually from `main` with `release` enabled.
That path runs every routed product check before it calls the reusable workflow
with permission to cut a new patch release. The Release workflow's manual entry
point cannot cut a new release directly because it only accepts a rebuild tag.

### Required secrets

| Secret | Why |
| --- | --- |
| `SPARKLE_PRIVATE_KEY` | Signs the appcast. Without it the workflow refuses to publish. |
| `MACOS_CERT_P12` | Base64 of the exported signing certificate and private key. |
| `MACOS_CERT_PASSWORD` | The password on that `.p12`. |
| `RELEASE_PUSH_TOKEN` | Pushes the release commit and tag to a protected `main`. |
| `TAP_PUSH_TOKEN` | Pushes the updated cask to `pulkitxm/homebrew-tap`. |

`main` is protected by a ruleset that requires pull requests and status checks. The
`GITHUB_TOKEN` an Actions run is given cannot bypass it, and the GitHub Actions app
cannot be added to a bypass list on a personal repository. The release jobs
therefore check out with `RELEASE_PUSH_TOKEN`, a fine grained personal access token
scoped to this repository with read and write access to contents. It acts as its
owner, and the ruleset already grants the repository admin role an unconditional
bypass, so pushes made with it are accepted. Without the secret the release fails
immediately with a message naming it, rather than building for ten minutes and
failing at the push.

`TAP_PUSH_TOKEN` is the equivalent for the Homebrew tap, scoped to
`pulkitxm/homebrew-tap`, and is documented in
[docs/homebrew-internals.md](docs/homebrew-internals.md).

### Optional notarization secrets

The workflow notarizes and staples the DMG when all three Apple credentials are
configured. A signed DMG is still published when they are absent.

| Secret | Why |
| --- | --- |
| `NOTARY_KEY_ID` | Identifies the App Store Connect API key used for notarization. |
| `NOTARY_ISSUER_ID` | Identifies the App Store Connect API key issuer. |
| `NOTARY_KEY` | Contains the App Store Connect API private key. |

`SPARKLE_PRIVATE_KEY` is the EdDSA key `generate_keys -x` exports, the private
half of `SUPublicEDKey` in `Info.plist`:

```bash
gh secret set SPARKLE_PRIVATE_KEY < sparkle-private.key
```

The workflow refuses to publish without it because a release whose `appcast.xml`
is missing or unsigned breaks in-app updates for everyone: Sparkle resolves the
feed from `releases/latest/download/appcast.xml`, so the newest release always
owns the feed.

The signing certificate is exported with:

```bash
security export -k ~/Library/Keychains/login.keychain-db -t identities \
  -f pkcs12 -P "<pick-a-password>" -o cert.p12
gh secret set MACOS_CERT_P12 < <(base64 -i cert.p12)
printf %s "<pick-a-password>" | gh secret set MACOS_CERT_PASSWORD
```

A Developer ID Application certificate is preferred for public distribution.
The workflow also accepts the configured Apple Development certificate so the
signed release flow remains available, but Gatekeeper can warn on other Macs.

The DMG is published as `Edith.dmg` rather than a versioned name so
`releases/latest/download/Edith.dmg` always resolves to the newest build, which
is what the website's download button uses.

### Why signing identity matters

macOS ties each permission grant to the app's code-signing designated
requirement, and a grant survives a reinstall only if the new build still
satisfies it. An ad-hoc signature pins the requirement to the binary hash, which
changes every build, so an ad-hoc DMG resets every permission on reinstall.

By default `codesign` writes a requirement naming the exact leaf certificate, so
grants still evaporate when that certificate is re-issued. When the identity
carries a team id, `build.sh` pins the requirement to bundle id plus team id
instead:

```
identifier "com.pulkit.edith" and anchor apple generic
  and certificate leaf[subject.OU] = "<team id>"
```

Every certificate the team owns satisfies that, so grants survive renewals and
the move to Developer ID. macOS records the requirement at the moment a
permission is granted, so reset once after installing a build made with this
change:

```bash
tccutil reset All com.pulkit.edith
tccutil reset All com.pulkit.edith.statusbar
```

## Website

`apps/site` is hand-written static HTML, CSS and JS with no framework, no build
step and no dependencies. GitHub Pages serves the folder as-is. `apps/site/CNAME`
must keep naming `edith.pulkit.page` or the deploy guard fails.
