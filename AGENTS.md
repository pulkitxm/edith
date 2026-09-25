# Agent guide

Edith lives in a private repository and its GitHub Actions are parked (the
workflow files sit in `.github/workflows-disabled/`, and Dependabot in
`.github/dependabot.yml.disabled`). Nothing runs checks or cuts releases for you
anymore. You do both locally. Treat these two rules as non-negotiable.

## 1. Keep every CI check green, locally

Before you hand back any change, the checks that CI used to gate on must pass on
this machine. Run them with the `Makefile`:

- `make ci-all` runs everything: comments, secrets, duplicate keys, lint, script
  tests, performance contracts, docs, companion runtime, site, promo, hygiene,
  security, the companion crate, and the full Swift build, lint, tests, and
  bundle verification. This is the gate.
- `make ci` runs the faster product subset when you only touched app code.
- Targeted checks exist for a focused change: `make ci-scripts`, `make ci-lint`,
  `make ci-swift`, `make ci-hygiene`, `make ci-security`, `make ci-companion`,
  and the rest. Run `grep '^ci' Makefile` to see them all.

First-time setup on a fresh machine:

- `bun install --frozen-lockfile` for the script and lint checks.
- `make ci-tools` installs the hygiene and security binaries (yamllint, lychee,
  gitleaks, trivy, osv-scanner, actionlint, zizmor, semgrep, cargo-audit, and
  the toolchains).
- Xcode is required for `make ci-swift`; point at it with `xcode-select` or
  `DEVELOPER_DIR` if the build cannot find it.
- `make ci-companion-migrate` needs a running pgvector database; start one with
  `ac` and pass `DATABASE_URL`.

Do not re-enable a workflow to "let CI check it." CI is off on purpose. If a
check only makes sense on GitHub, run its local equivalent above.

## 2. Cut a release yourself after a PR merges

CI no longer builds, signs, or publishes anything, so once a pull request is
merged to `main` you cut and push the release:

```sh
git checkout main && git pull
make release
```

`make release` resolves the next version, builds and signs the release app,
packages and verifies the DMG, generates the signed Sparkle appcast, stamps the
version files and cask, then commits and tags on `main` and publishes the GitHub
release with its assets, all through Pukbot so the automated release commit is an
app-authored bot commit. Use `make release-dry` to build and verify without
committing or publishing.

Requirements:

- A `.env` at the repository root holds the signing material
  (`MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `SPARKLE_PRIVATE_KEY`,
  `EDITH_SIGN_IDENTITY`). It is git-ignored. Without it, `make release` stops.
- The certificate is an Apple Development cert, so the build is dev-signed and
  not notarized, exactly as CI did it. Gatekeeper warns on other Macs.
- Because the repository is private, the appcast and DMG download URLs need
  authentication, so Sparkle auto-update and the Homebrew tap no longer serve
  public users. The release still exists for install and record.

## Bringing CI back

Move the workflows back into `.github/workflows/` and Dependabot back to
`.github/dependabot.yml`, once the account's Actions billing is healthy. The
tests under `scripts/` validate the parked workflow files in place, so they stay
correct and ready. See `.github/workflows-disabled/README.md`.
