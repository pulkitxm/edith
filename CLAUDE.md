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

## Checks

- `bun run check-comments` — no disallowed comments (all tracked source).
- Swift checks run from `apps/macos/`: `swift build` (type-check), `swift test` / `./test.sh` (tests),
  `swift format lint --strict --recursive Sources Tests Package.swift` (format + lint).
- `bun run lint` — Biome format + lint for the dashboard.
- `bun test apps/dashboard/tests scripts` — JS tests.
- `cd apps/promo-video && npm ci && npx tsc --noEmit` — promo-video (Remotion) type-check.
