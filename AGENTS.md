# Agent guide

GitHub Actions runs the checks and cuts the release. Workflows live in
`.github/workflows/`, and Dependabot in `.github/dependabot.yml`. A pull
request runs the checks. A push to `main` runs them again, and a product
change on `main` publishes the next release.

## Shared screen UI

- Compose scrolling pages with `PageScaffold` and pane-based tools with
  `PageWorkspace`. Reuse `PageHeader`, `PageSectionHeader`, and `PageMetrics` for
  structure and responsive headers. Read `compactLayout` from the window host
  instead of defining another breakpoint inside a page.
- Use `EdithSegmentedPicker` for segmented choices. Native segmented pickers
  have intrinsic label widths that can overflow inspectors and compact windows.
- Use `ContentLoad` for request ownership and loading state, `PageLoading` for
  page-level presentation, and `LoadingContainer` for component-level content.
  Choose a shared `PageSkeleton` recipe instead of writing feature-specific
  full-page placeholders. `LoadingIndicator`, `SkeletonBlock`, and
  `SkeletonReplica` share the same animation. Keep compute-heavy construction
  behind loading, retain content during refresh, and expose recovery actions.
- Use `pageTask` and `pageRefresh` for page work and observation. They share
  window visibility, automatic-action, and cancellation rules. Retained editors,
  recordings, terminals, and app services belong to their resource owners.
- Present sheets through the shared presentation API so Escape and outside
  clicks behave consistently. Disable dismissal while an operation owns the
  presentation or when closing would discard unsaved edits.
- Reuse the shared export and activity components for usage and code statistics
  instead of creating feature-specific renderers, delivery helpers, or grids.
- Use the selected app theme, `UIScale`, `Motion`, and shared surface and control
  styles. Semantic status colors and exported artwork palettes may differ.
- Use `Font.edithText` for semantic text styles so headings, captions, and
  editor labels follow window zoom.
- Verify screen layouts at compact and regular widths, increased zoom, and both
  color schemes. Global navigation shortcuts belong to the window router and
  must work when a terminal, web view, or text field is the first responder.
- Keep source code comment-free. Functional tooling directives and license
  blocks are the only exceptions. Run `make ci-comments` before submitting.

See `docs/shared-screen-architecture.md` for the loading and ownership contract.

## Development builds

Every worktree builds and runs its own development app, so several branches can
run at once next to the installed Edith without touching it or each other.

- `./build.sh` builds, stops this worktree's previous development build, and opens
  `dist/Edith.app`. It runs as `Edith (<slot>)` with bundle identifier
  `com.pulkit.edith.dev.<slot>`, where the slot is the worktree folder name
  without the `edith-` prefix (`main` for the primary checkout). Use
  `./build.sh --no-open` to build without launching.
  `./build.sh --background` builds the same way, then launches that development build hidden so its windows stay off-screen.
- Each slot has its own background agent (`com.pulkit.edith.dev.<slot>.agent`),
  menu bar helper, preferences, keychain items and data under
  `~/Library/Application Support/Edith Dev/<slot>`, with caches and logs under
  the matching `Caches` and `Logs` folders. A new slot starts empty and asks for
  macOS permissions again.
- Talk to a development build with its own CLI,
  `dist/Edith.app/Contents/MacOS/ed`. The `ed` on your `PATH` is the installed
  app's CLI and reaches the installed agent.
- The app loads its agent with `launchctl bootstrap` when it opens and unloads
  it, along with its menu bar helper, when it quits. Development builds never
  register login items or the lid-awake daemon, so never register or restart the
  production labels (`com.pulkit.edith.agent`, `com.pulkit.edith.helper.v2`,
  `com.pulkit.edith.lidawake.v2`) from a development build or by hand.
- Run `./build.sh --teardown` before deleting a worktree. It stops the build and
  removes its data, preferences, keychain items and permission grants.
  `./build.sh --gc` does the same for slots whose worktree is already gone and
  removes production copies outside `/Applications` from LaunchServices.
- If `build.sh` reports that a slot belongs to another worktree, rename this
  worktree's folder rather than deleting the other slot.
- Only `/Applications/Edith.app` runs as Edith. `./build.sh --release --install`
  is the only way to replace it; a Release build left in `dist/` is never opened
  and refuses to start there.

See `docs/background-agent.md` for how the identities, agent loading and
LaunchServices cleanup work.

## Make resource gate

Heavy `make` targets share one machine-wide budget: app builds, Ghostty,
Swift and Cargo test builds, security scans, and the JS tool targets. A
light target such as `make ci-comments` does not take a slot. Before a heavy
target starts, `scripts/make-resource-gate.py` records its pid and name in
`~/.cache/edith/make-slots` and admits it only when free CPU and memory cover
what that target tends to use. Load average accounts for other work. Each
running make also counts the cpu it is using right now, which load average
has not caught up to yet, plus a reservation for what it has not allocated:
the full estimate for the first 20s, then at least half, or more when live
usage is higher. Available memory already includes allocations, so that part
is not reserved again. A quiet 14-core machine fits about three app builds.
A busy one fits fewer. Set `EDITH_MAKE_GATE=skip` to run immediately.

When the budget is short, the gate waits and prints `make-resource-gate:`
lines on stderr: the reason, the host budget, each running pid and target,
and that it checks every 5 seconds and gives up after 5 minutes. A later line
says `still waiting` with how long is left. If the wait expires, the target
does not start.
