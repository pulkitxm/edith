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
./build.sh --release --install
make ci-host
make ci-extension-support
make ci-extension-<id>
```

Default builds are development builds. Each worktree builds its own app,
`com.pulkit.edith.dev.<slot>`, displayed as `Edith (<slot>)`, where the slot is the
worktree folder name without the `edith-` prefix (`main` for the primary checkout).
Its settings and data under `Edith Dev/<slot>` belong to that worktree alone, so
several branches run side by side without touching each other or the installed
app. `./build.sh --teardown` deletes the current worktree's slot, including its
preferences and permission grants; `./build.sh --gc` does the same for slots whose
worktree is gone. `--branch` and `--pr` select the source without enabling
installation. `make install` and `make reinstall` build a Release configuration
before replacing the installed app, and only `/Applications/Edith.app` runs as Edith.
Local installation reads signing settings from `.env` in the selected worktree,
falling back to the primary checkout. It imports the configured certificate into
a temporary keychain when needed and removes that keychain after the build.
Developer ID signing remains the default. Local development signing requires
`EDITH_RELEASE_ALLOW_DEV_SIGNING=1` in the signing configuration.

Needs Xcode, not just Command Line Tools. `build.sh` runs
`scripts/build-minimal-host.mjs`, which builds the `Packages/EdithHost` SwiftPM
package into a small host app, then `scripts/package-shipping-host.py`, which
embeds Sparkle, the `ed` launcher and the resources in `Resources`, and signs the
bundle into `dist/Edith.app`. Features are not part of the host. Each one is an
extension under `Extensions/<id>` that is built and released as its own package
with `bun scripts/build-extension-package.mjs <id>`, and `make extension-dev
EXTENSION=<id>` builds one for development.

To exercise an extension change in a running development build before it is
published, run `make extension-sideload EXTENSION=<id>` in the same worktree.
It builds an ad-hoc signed package with a fresh patch version and installs it
with `dist/Edith.app/Contents/MacOS/ed extensions sideload <package.zip>`,
replacing the catalog version in that slot only. Release builds refuse
sideloaded packages.

The signature is applied by `package-shipping-host.py` rather than left to a
build tool. A designated requirement that names the exact leaf certificate
stops matching when the certificate is re-issued, and macOS then drops every TCC
grant the app had: Screen Recording, Accessibility, Calendar. Pinning the
requirement to bundle id plus team id instead survives that. The identity is
`EDITH_SIGN_IDENTITY`, else the first available Developer ID Application,
self-signed `Edith Dev`, or Apple Development certificate, else ad-hoc. Ad-hoc
signatures change on every rebuild, which is what resets those grants, so for
day-to-day work create a self-signed certificate once through Keychain Access,
Certificate Assistant, Create a Certificate, named "Edith Dev", Identity Type
"Self Signed Root", Certificate Type "Code Signing".

The source tree is organized by package:

| Path | Responsibility |
| --- | --- |
| `Packages/EdithHost` | The host app: lifecycle, navigation, Home, Notch, Extensions, Storage and Settings pages, and the extension loader. |
| `Packages/ExtensionMarketplace` | Catalog, package verification, installation and compatibility rules shared by the host and the release tooling. |
| `Packages/ExtensionSupport` | Libraries that extensions link: commands, files, accounts, documents, archives and shared UI. |
| `Packages/EdithStudio` | The Studio media engine. |
| `Packages/EdithDocsWorker` | The bundled `ed` reference. |
| `Extensions/<id>` | One extension: its runtime, views, CLI commands and tests. `Extensions/manifest.json` lists them all. |

The app icon is drawn in `Resources/AppIcon.svg`. `make icon` renders it with
Chrome and derives the checked-in `AppIcon.icns`, the site icons and the promo
video logo from that. Run it after changing the SVG.

The Spotify player in `apps/music-player` is a Rust crate. Run
`cargo test --locked` and `cargo clippy --locked --all-targets -- -D warnings`
in that directory when changing playback commands or account handling.

### Companion backend

`apps/companion` is a Rust 2024 Axum service backed by PostgreSQL with pgvector,
Redis, Ollama and Whisper. The app's guided setup packages the runtime files and
deploys the stack to this Mac or a registered SSH machine. It selects the Apple
Metal, GPU or CPU Compose overlay from the host it probes.

For backend-only work, install stable Rust with Clippy and use:

```bash
make prepare-pdf-extract
cd apps/companion
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
```

Migration tests also need a pgvector PostgreSQL 18 instance. CI supplies one and
runs `cargo run --locked -- --migrate-only` with `DATABASE_URL` set. The complete
end-user deployment and data model are in the
[Companion guide](docs/companion.md).

## Checks

CI runs the applicable macOS, site, script and policy gates for every pull
request and push to `main`. Run `make ci` when you want the full check suite on
demand. Companion changes have additional commands below and a dedicated CI
job.

| Target | What it does |
| --- | --- |
| `make ci` | All macOS, script, site, and policy checks below, after `bun install --frozen-lockfile`. |
| `make ci-comments` | Fails on any disallowed comment in tracked source. |
| `make ci-secrets` | Scans every tracked file for leaked secrets. |
| `make ci-duplicate-keys` | Fails when a `UserDefaults`/`SharedDefaults` key is spelled out as a raw string literal in more than one Swift file instead of going through one shared constant. |
| `make ci-lint` | Biome format and lint for `scripts/` and `apps/site`. |
| `make ci-scripts` | The `bun test` suite for `scripts/`. |
| `make ci-promo` | `npm ci` and type check for the Remotion promo video. |
| `make ci-swift-lint` | `swift format lint --strict` over the host, marketplace, support, docs worker and extension sources. |
| `make ci-swift-build` | A full release `build.sh` followed by `make verify-bundle`. |
| `make ci-host` | Format, build and test `Packages/EdithHost`. |
| `make ci-extension-support` | Format and test `Packages/ExtensionSupport` and the shared `Extensions` package. |
| `make ci-studio` | The EdithStudio test suite. |
| `make ci-swift-test` | The host, marketplace, extension support and docs worker tests. |
| `make ci-swift-check` | Lint, build and test as one on-demand local target. |
| `make ci-swift` | `ci-swift-check` plus a full `build.sh` and `make verify-bundle`. |
| `make verify-bundle` | Bundle layout and codesign assertions against `dist/Edith.app`. |

For Companion backend changes, run the Clippy and Cargo tests shown above. CI also
applies every migration to a real
pgvector database. These checks are not part of `make ci`.

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

Merging application changes into `main` publishes a new patch version through the
CI workflow. Its `version` and `dmg` jobs prepare the signed DMG alongside the
routed checks, notarize it when Apple credentials are available, and generate the
signed Sparkle appcast. The `publish` job waits for the required checks to pass
and the DMG build to succeed without being superseded before publishing both
assets to one GitHub Release. All jobs appear in the same CI run on the commit.
The versioned plists and cask land together in one release commit and tag, and the
cask is mirrored to the tap.

To rebuild an existing release, run the CI workflow manually from `main` with
`rebuild` set to the current tag. Only the current release can be rebuilt. The
rebuild replaces its two assets, commits a changed DMG checksum to `main` when
needed, and mirrors the same cask to the tap. It does not create a new version or
tag. To recover a skipped automatic release, run CI manually from `main` with
`release` enabled. Both manual release paths run the product checks and use the
same publication gate. Choose either `release` or `rebuild`, not both.

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
tccutil reset All com.pulkit.edith.helper.v2
```

## Website

`apps/site` is hand-written static HTML, CSS and JS with no framework, no build
step and no dependencies. GitHub Pages serves the folder as-is. `apps/site/CNAME`
must keep naming `edith.pulkit.page` or the deploy guard fails.
