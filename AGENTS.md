# Edith

## Code style: no comments

Do not write comments in code. This repo is kept comment-free and CI enforces it.

- Applies to Swift, JS/MJS, CSS, JSON, YAML, and HTML.
- Allowed exceptions are functional directives only: `// swift-tools-version`,
  `// swiftlint:...`, `// swift-format...`, `biome-ignore`, `@ts-*` / `eslint-*`,
  and `/*! ... */` license blocks.
- Clean stray comments with `bun run strip-comments`.
- `bun run check-comments` is what CI runs; it fails on any disallowed comment.

Write code clear enough not to need comments. If a name or a block needs
explaining, improve the name or the structure instead of adding prose.

## Code standards: one source of truth, reused everywhere

- `UserDefaults`/`SharedDefaults` keys live once in `AppStorageKeys`
  (`Sources/EdithKit/Core/AppStorageKeys.swift`), grouped by feature. Reference the
  constant; do not retype the key string at a second call site.
- Bundle identifiers and other app-identity strings live on `MainApp`
  (`Sources/EdithKit/Core/MainApp.swift`). A default value shared by an `@AppStorage`
  property and a plain `UserDefaults` fallback lives as a `static let` next to the
  logic that owns it, not as two independently typed literals.
- Shared, cross-feature SwiftUI views and modifiers live in `Sources/EdithKit/UI`.
  Check there before adding a new chip/badge/card/row that copies an existing one's
  modifier chain with different content.

## Layout

Every Swift source lives in one SwiftPM package, `Packages/Edith`: `Sources/Edith`
(main app UI), `Sources/EdithKit` (shared core), `Sources/EdithCLI`, the vendored
`Vendor/Highlighter`, thin `Sources/{EdithMain,EdithFiles,EdithHelper,ed,edh}`
entry points, and `Tests/EdithTests`. `edth.xcodeproj` builds the app bundles from
those same directories through folder-synchronized groups, so a new file needs no
project edit: drop it in the target's directory and it builds. Never add a second
copy of a source tree; there is one.

## Checks

- `bun run check-comments` - no disallowed comments (all tracked source).
- `bun run check-duplicate-keys` - no `UserDefaults`/`SharedDefaults` key spelled out as a raw
  string literal in more than one Swift file; add it once to `AppStorageKeys` instead.
- Swift checks: `make ci-swift-check` runs all of it. The three halves are separate
  targets, and nothing makes you wait for the others: `make ci-swift-lint`
  (`swift format lint --strict`), `make ci-swift-build` (one `xcodebuild`), and
  `make ci-swift-test` (`./test.sh`). The build and the tests use different build
  systems and different build trees, so they run in parallel.
- Build the `EdithMain` scheme alone to type-check everything: it lists `EdithHelper`,
  `EdithFiles`, `ed` and `edh` as target dependencies, so all five targets compile.
- `bun run lint` - Biome format + lint for the dashboard.
- `bun test apps/dashboard/tests scripts` - JS tests.
- `cd apps/promo-video && npm ci && npx tsc --noEmit` - promo-video (Remotion) type-check.
