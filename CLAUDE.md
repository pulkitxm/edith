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

## Delegating to Codex (make jobs finish fast)

Codex runs in a sandbox that HANGS on any command over ~10 minutes: `swift build`,
`./build.sh`, `bun run build`, `./test.sh`, full test runs. A hung job burns hours of
wall-clock while consuming almost no tokens (the tell: low token count + long elapsed +
its log going silent right after "File changes completed" or looping on `git diff`). To
avoid this:

- Give Codex WRITE-ONLY tasks. Every prompt says: "no `swift build`/`swift test`/
  `./test.sh`/`./build.sh` or any command over 60 seconds; `swift format lint --strict`
  and fast static checks only." The reviewer (main session) compiles, tests, and commits.
- Put a startup delay before polling a new job's status (it takes a few seconds to
  register; polling too early reports 0 running and fires waiters prematurely).
- If a job is quiet for a long stretch, treat it as wedged: cancel it and verify the
  changes it already applied to the working tree, rather than waiting.
- Codex processes have NO Screen Recording / Accessibility TCC grants; drive any UI
  screenshotting or synthetic-input testing from the main session, not Codex.

## Recurring integration fixes (apply before building)

- A Swift `switch` used as an expression in a function that returns a value needs an
  explicit `return switch ... { }`; Codex often omits it.
- Never leave `#Preview { }` macros in SwiftUI files: they fail the command-line SwiftPM
  build ("PreviewsMacros plugin not found").
- `swift test` fails with "no such module 'Testing'" under Command Line Tools; run
  `Packages/Edith/test.sh`, which adds the CLT Testing.framework search paths.

## Committing around protected work-in-progress

The tree often holds unrelated uncommitted work. Stage explicit paths, never `git add -A`;
after each Codex task, commit only that task's files. Committing a file DELETION (e.g. a
replaced stylesheet) is required or the `check-comments` pre-push hook ENOENTs on the still-
tracked path. The lefthook pre-push runs the full swift build + tests + comment check; when
it fails only because of another in-flight job's tree state, push with `--no-verify` AFTER
running build/tests/comment-check yourself on the staged files.

## Every UI action needs a CLI verb

The app and `ed` are peers over one shared core in `EdithKit`, not client and
server. Neither shells out to the other, so parity is a rule rather than a
consequence: anything the UI can change, `ed` must be able to change too, through
the same function.

- Mutations live in `EdithKit` (`ClipboardActions`, `MachineRegistry`, ...). Views
  and CLI commands call them; neither reads-modifies-writes a store file itself.
- Adding a UI action means adding a row to `UIParity.capabilities` in
  `Tests/EdithTests/CLIParityTests.swift` naming the `ed` verb that does the same
  thing. There is no "no CLI for this" option: an action whose state lives only in
  the running app still gets a verb that asks the app and says to open it when it
  is closed, the way `ed machines files undo` does.
- `UIParity.notReachableFromTheUI` is the only escape hatch, it is for commands with
  no UI counterpart rather than the reverse, and every entry must say in a sentence
  why. `everyExemptionSaysWhyItIsOneAndIsStillNeeded` fails on a placeholder reason
  and on an entry nothing would have flagged.
- `everyMutatingCommandIsClaimedByAUIAction` fails when a mutating verb has no row,
  and `everyUIActionParsesWithTheArgumentsItClaims` fails when the verb it names
  does not exist or does not take those arguments.
- A new command also needs a `CommandNode` in `CommandTree.swift` (completion), a
  `JSONCase` in `CLIContractTests.swift` if it takes `--json`, its own page under
  `docs/cli/<group>/`, and an entry in `Guide.swift`.
  `CLIDocsTests.everyCommandInTheTreeIsDocumented` fails when a command in the tree
  is documented nowhere, and `everyCommandPageIsListedByItsGroup` fails when the new
  page is not linked from its group's `README.md`.

## Documentation

`docs/cli/` is the CLI reference, one page per command. `README.md` is the index and
links every group; each group is a directory whose `README.md` introduces the group
and links its commands in the order they should be read; every other file documents
exactly one command and opens with that command as its `# ` title. A command page
ends by linking back to its group, and a group links back to `./README.md`, which is
what keeps the generated wiki navigable. It is the only place the CLI is documented
at length; the root `README.md` links to it rather than repeating it.

Four tests hold that shape: `everyGroupIsListedInTheIndex`,
`everyCommandPageIsListedByItsGroup`, `everyPageLinksBackToItsIndex` and
`everyRelativeLinkResolves`.

`scripts/sync-wiki.mjs` mirrors `docs/` into this repo's GitHub wiki, one wiki page
per markdown file, plus a generated `Home`, `_Sidebar` and `_Footer`. A group becomes
`CLI-<Group>` and its commands `CLI-<Group>-<Command>`, nested one level under the
group in the sidebar and ordered the way the group `README.md` links them. Relative
links between docs are rewritten to wiki slugs. `.github/workflows/wiki-sync.yml` runs it
on every push to `main` that touches `docs/`. Preview the output locally with
`make wiki` (writes `.wiki-build/`, never pushes); `make wiki-push` publishes.
The wiki is generated output: edit `docs/`, never the wiki.

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
- Swift checks: `make ci-swift-check` runs all of it. The three halves are separate
  targets, and nothing makes you wait for the others: `make ci-swift-lint`
  (`swift format lint --strict`), `make ci-swift-build` (one `xcodebuild`), and
  `make ci-swift-test` (`./test.sh`). The build and the tests use different build
  systems and different build trees, so they run in parallel.
- Build the `EdithMain` scheme alone to type-check everything: it lists `EdithHelper`,
  `EdithFiles`, `ed` and `edh` as target dependencies, so all five targets compile.
  Looping over the schemes only pays xcodebuild's startup four more times.
- `bun run lint` - Biome format + lint for `scripts/` and `apps/site`.
- `bun test ./scripts` - JS tests. Do not pass a bare `scripts`; it also matches the
  gitignored `extras/` tree and reports unrelated failures.
- `cd apps/promo-video && npm ci && npx tsc --noEmit` - promo-video (Remotion) type-check.
- `make wiki` - render the wiki into `.wiki-build/` to check what a push would publish.

## Website

`apps/site` is hand-written static HTML, CSS, and JS with no framework, no build step,
and no dependencies. GitHub Pages serves the folder as-is via `.github/workflows/pages.yml`,
which only runs when `apps/site` changes. `apps/site/CNAME` must keep naming
`edith.pulkit.page` or the deploy guard fails. Serve it locally with `make site-dev`.
