# Native interface and performance audit

Captured 2026-08-26 at commit `cbbc6ee4` before production changes.

## Scope and method

Edith is a native macOS control center with a shared Swift package for the main app,
menu bar helper, command line tools, shared services, and platform-neutral models. The
package targets macOS 14 and conditionally adopts newer stable APIs. The audit covered
all source files under `Packages/Edith/Sources`, the optional Companion backend, current
tests and performance contracts, a Release build, the running product, and five
production Mac applications.

The Release build completed from this worktree and the built application opened with a
usable main window and accessible navigation. The first attempt correctly failed until
the repository's pinned Ghostty framework was built with `make ghostty`.

The initial timing capture used an Apple M4 Pro MacBook Pro with 14 cores and 24 GB of
memory on macOS 26.6.1. It ran on battery power under an active development workload, so
these values establish a current observation, not a final acceptance baseline. Formal
before and after comparisons must use isolated synthetic data, the same power mode,
thermal state, display configuration, build, and network profile.

## Product benchmark

The benchmark inspected Finder, System Settings, Activity Monitor, App Store, and
TextEdit. It extracted interaction principles rather than layouts or visual assets.

| Application | Relevant behavior | Principle for Edith |
| --- | --- | --- |
| Finder | Resizable source sidebar, toolbar actions, native selection, status bar, disabled actions when selection is absent | Let selection and window state drive semantic controls; keep common actions in stable locations |
| System Settings | Searchable category sidebar, back and forward history, leading content column, native settings controls | Use adaptive category navigation and keep content aligned with the selected category |
| Activity Monitor | Sortable table, toolbar mode selection, contextual action enablement, persistent summary | Use native tables for dense data and keep summary information separate from row actions |
| App Store | Persistent high-level navigation, immediate shell, independently loaded detail content | Render navigation and page identity before optional content arrives |
| TextEdit | Native file panel, standard keyboard order, coherent disabled and default actions | Prefer system controls and panels so focus, keyboard, and active-window behavior arrive together |

Across the benchmark, sidebars remain broad and shallow, toolbars hold frequent actions,
selection is visible without hover, controls use the arrow pointer unless they are links,
and native focus and disabled states carry most interaction feedback.

## Surface inventory

### Main process

- Main window with Home, Attention, Agent Usage, Herdr, Quinjet, Music, Calendar,
  System, Machines, Companion, Extensions, Settings, and About destinations.
- Detached windows for every primary destination, with native window tabbing.
- Onboarding, Herdr agent, Machine detail, terminal, Finder, Docker, and nested Edith
  Files windows.
- Main menu commands for windows, navigation, page selection, pane selection, terminal
  selection, zoom, and file browsing.

### Page families

- Dashboard: Home and Agent Usage summaries, charts, filters, budgets, limits, and
  project drilldown.
- List and table: Attention timelines, running applications, processes, containers,
  images, volumes, networks, downloads, clipboard history, and music tracks.
- Detail: machine, container, file, project, track, episode, and memory detail.
- Settings: General, Permissions, Shortcuts, Terminal, iCloud, and Updates.
- Media: Music library, playback footer, track detail, video preview, and downloader.
- Terminal: Machine, Workspace, Quinjet, and Herdr terminal surfaces.
- Onboarding: welcome flow and Companion setup flow.
- Helper: Agent Usage, Music, System, Calendar, clipboard, color, audio, camera, notch,
  cleaning, focus, and status item surfaces.

### Overlays and commands

The product uses sheets, alerts, popovers, context menus, native file panels, status
menus, floating panels, per-display overlays, and detached windows. Major overlay owners
are Dashboard filters, extension setup, Companion setup and data controls, machine and
Docker operations, Finder conflicts and info, music file operations, update scheduling,
Lid Awake controls, clipboard history, and notch shelf actions.

### Command line

`ed` exposes the command implementation and `edh` is its packaged alias. The
command tree contains 390 paths including root and generated help, 340 leaves,
337 reference pages, and 40 explicit destructive routes. Top-level groups cover
guide and schema discovery,
configuration, app operations, extensions, permissions, usage, system, music, calendar,
presenter mode, Herdr, clipboard, attention, downloads, running apps, tools, color,
shelf, cleaner, Quinjet, machines, and Companion.

The current contract already separates stdout data from stderr diagnostics, emits one
JSON document for almost every JSON command, documents exit codes, preserves remote
process streams, and previews destructive work before `--yes` execution.

## Ownership and lifetime

### Main app

- `MainAppDelegate` owns process startup, settings and quit observers, helper
  maintenance, cleanup, and staged post-launch work.
- `MainWindow` owns the primary window and a process-long updater after first access.
- `MainWindowView` owns keyboard monitors, permission refresh work, and music resource
  activation for the visible root view.
- Dashboard, Machines, Music, and Herdr use shared process-lifetime models. Detached
  windows share them, so page disappearance cannot be treated as sole ownership.
- Companion creates all page models eagerly. Its capture and library models construct
  audio resources before those destinations are visited.
- Terminal tabs own subprocess-backed sessions, but application termination has no one
  coordinator that closes every main-process terminal and machine owner.

### Helper

- `AppServices` owns enabled feature modules from reconciliation until disable or
  process exit.
- Process-long services own usage polling, media timers, system health timers, machine
  monitoring, clipboard polling, attention recording, status items, backups, panels,
  hotkeys, and IPC observers.
- Helper termination has a bounded coordinator for safety and persistence, but it does
  not call the ordinary shutdown path for every module.

### External work

- Shared IPC uses distributed notifications delivered on the main queue.
- Machine sessions may own SSH master and stream processes, polling tasks, reconnect
  supervision, mounts, Docker state, and watchdogs.
- Shared process runners provide good bounded and cancellable patterns, but direct
  synchronous process waits remain in local machine sampling, media scripting, and
  Companion probing.
- Companion uses URL sessions and local or SSH-hosted services. Contributor loading,
  machine access, and attention listeners add other network boundaries.

## Current observations

### Layout and interaction

- `PageHeader` establishes only a title row and basic gutter. Quinjet bypasses it,
  Dashboard adds another top band, About centers itself, and Companion adds a second
  gutter.
- Settings places a six-category segmented picker under the page title while grouped
  forms start in an unrelated centered column. Wide windows amplify the disconnect.
- Complex pages independently define action bands, tabs, chips, cards, selection rows,
  spacing, type, borders, and hover effects.
- Shared interaction does not cover focused, selected, disabled, inactive-window,
  default-action, and keyboard states as one policy.
- The source contains about 389 pointer cursor modifiers, 29 tap gestures, 48 progress
  views, 12 skeleton declarations, and 139 animation or transition sites.
- Ordinary actions still use gestures in clipboard, project, Herdr, workspace, music,
  color, and cleaner surfaces. Quinjet contains a nested button. Home hides a required
  clock action until hover.
- The general pointer helper applies a hand cursor to ordinary controls, which conflicts
  with macOS pointer conventions.

### Loading and motion

- Machines, Herdr, Companion, Cleaner, Dashboard, and helper pages use separate loading
  systems. There is no shared delayed indicator, cached refresh, partial, offline,
  retry, cancellation, or reserved-geometry policy.
- Skeleton blocks can run independent repeating phases, and one drive skeleton does not
  honor Reduce Motion.
- `Motion.animation` replaces reduced motion with a shorter animation. It does not
  remove translation, scale, rotation, or shimmer. Several feature transitions bypass
  the shared policy.
- Broad parent animation modifiers can animate unrelated descendants.

### Performance

- `MainWindowView` observes more than twenty shared defaults at the root. Any mutation
  can reevaluate the shell and active destination.
- Machine fleet appearance connects every configured host without a fleet-level bound,
  retains sessions process-wide, and retries recoverable failures indefinitely.
- The local machine slow sampler launches `pmset`, reads its output, and waits for exit
  from a MainActor-owned loop.
- Every shared-defaults change becomes one untyped helper notification. The helper then
  reconciles every service group and refreshes panels, menus, sleep, Lid Awake, focus,
  and presenter state.
- Dashboard cancels superseded filter tasks, but the detached computation lacks
  cooperative cancellation checks and can continue consuming CPU.
- Home uses several independent timeline publishers while visible.
- Music rows start duration, artwork, and recursive folder-count work. Lazy containers
  limit visibility, but several caches are unbounded and folder scans bypass the shared
  metadata gate.
- Attention already combines workspace events with a heartbeat needed for idle
  transitions. An event-only rewrite is not justified without measurement.
- Main quit cancels startup work but has no app-wide shutdown owner. Helper quit can wait
  up to five seconds for safety and persistence.

### CLI

- Static command paths still link through AppKit-facing adapters. `version --json`
  probes running applications, and completion can load machine, music, calendar,
  usage, contributor, app, Quinjet, or remote state depending on route.
- `TextTable` uses character count instead of terminal display width, ignores terminal
  columns, and cannot choose, wrap, or collapse columns for narrow output.
- Progress has fixed widths, appears immediately, and is not one unified determinate or
  indeterminate model.
- Some Companion and media process paths synchronously wait, drain streams serially, or
  lack bounded output and structured cancellation despite safer shared runners already
  existing.

## Preliminary measurements

The installed Release build and the worktree build both reported version `0.0.164`.
Thirty process samples used one-second intervals. Thirty CLI samples used the worktree
Release executable in a fresh process per invocation after three warmups. Raw samples
and capture conditions are retained in
`performance/baselines/native-revamp-2026-08-26.json`.

| Scenario | p50 | p95 | Observation |
| --- | ---: | ---: | --- |
| Main process with a live data page visible, CPU | 0.15% | 22.3% | Background refresh work made the upper tail bursty |
| Main process RSS | 143.9 MB | 152.5 MB | Active extensions and live data were enabled |
| Helper CPU | 0.1% | 1.7% | One 30-second window does not cover every five-minute timer |
| Helper RSS | 116.8 MB | 126.6 MB | Active extension set, not a minimal profile |
| `ed --help` | 9.0 ms | 9.7 ms | Meets the initial static command target |
| `ed --version` | 8.5 ms | 9.4 ms | Meets the initial static command target |
| static zsh completion generation | 65.8 ms | 67.5 ms | Meets the initial target with a 182 KB payload |
| `ed schema` | 9.8 ms | 10.6 ms | Meets the initial static command target |

Opening the freshly built Release application returned from Launch Services in about
100 ms and produced an accessible main window. A direct termination signal removed only
the audit instance in about 134 ms. Neither value represents first frame or the normal
AppKit quit request path, so both require dedicated instrumentation before optimization.

## Prioritized problems

1. Establish isolated, raw-sample launch, navigation, interaction, quit, helper, and CLI
   baselines before retaining optimizations.
2. Remove recurring local machine process and disk work from MainActor.
3. Add explicit app and helper shutdown ownership, then measure safety and persistence
   stages independently.
4. Bound and lease machine connections across main and detached windows.
5. Replace untyped settings-wide reconciliation with changed domains.
6. Narrow root shell observation and stop inactive optional resources.
7. Make dashboard computation cancellation cooperative.
8. Lazily create Companion media resources and batch or bound Music metadata work.
9. Consolidate page, settings, button, loading, motion, focus, and pointer policies.
10. Unify CLI presentation, terminal width, progress, lightweight startup, and process
    execution.

## Native component architecture

- `AppWindowShell`: title bar integration, navigation, detail content, footer,
  active-window state, and window sizing.
- `NavigationSidebar`: native selection, detachment, keyboard traversal, and context
  actions.
- `PageShell`: explicit dashboard, list, table, detail, settings, media, terminal,
  onboarding, and helper variants.
- `PageHeader`: title, optional subtitle and status, primary action, secondary actions,
  and one accessory row.
- `ContentGrid`: regular or readable width, always leading-anchored.
- `SectionHeader` and `GroupedSurface`: shared hierarchy and geometry without replacing
  native List, Table, Form, Section, or LabeledContent behavior.
- `SettingsShell`: adaptive category sidebar, preserved `settingsTab` deep links and
  history, leading content, and narrow-window behavior.
- Semantic button roles: primary, secondary, borderless, toolbar, destructive, row,
  icon-only, and selection.
- `ContentStateContainer`: cached refresh, delayed loading, partial, empty, error,
  offline, retry, cancellation, and success.
- `MotionPolicy`: semantic transitions selected from Reduce Motion, Prefer Cross-Fade,
  transparency, contrast, and differentiation settings.

Specialized terminal rendering, direct manipulation splitters, Finder selection
gestures, and the notch shelf remain specialized.

## Performance architecture

- Add stable signposts for process start, shell visible, first frame, first usable input,
  first useful content, navigation, load publication, quit stages, and CLI dispatch.
- Use isolated defaults profiles and deterministic generators for minimal, all-enabled,
  large dashboard, machine fleet, music library, Companion, attention, terminal, and
  quit scenarios.
- Introduce lease-based feature ownership where a surface can exist in the main window
  and detached windows.
- Keep UI state on MainActor. Run measured CPU, file, process, and network work behind
  explicit async boundaries with structured cancellation, bounded concurrency, bounded
  output, and generation checks.
- Persist important state incrementally. Quit only awaits bounded safety-critical work.
- Give the CLI one presentation context and one process executor, while keeping JSON
  serialization independent from human rendering.

## Delivery stack

1. Measurement foundation and deterministic fixtures.
2. Interaction primitives, motion, loading, focus, and hit-target policy.
3. Application shell, navigation, page layout, and Settings.
4. Home, Agent Usage, Attention, Extensions, About, Calendar, and System.
5. Machines, Finder, Docker, Herdr, Quinjet, and terminal ownership.
6. Music and Companion lifetime, loading, and metadata work.
7. Helper and menu bar surfaces, settings domains, and termination.
8. CLI presentation, subprocess safety, startup, completion, documentation, and parity.
9. Accessibility, visual regression, and final performance verification.

Each pull request must stay coherent and below about 2,000 changed lines. A stack may
split any numbered item further when a focused change would otherwise approach that
limit.

## Risks and dependencies

- Shared models serve detached windows. Naive `onDisappear` shutdown can break another
  visible owner.
- Settings deep links are persisted strings used by main navigation and helper routes.
- Machine, terminal, Lid Awake, backup, and Companion work cross process or host
  boundaries and need explicit ownership before shutdown changes.
- A Release app needs the pinned Ghostty framework and the supported signing workflow.
- Launch and energy comparisons are sensitive to power, thermal, network, display, and
  cache state.
- Accessibility changes must preserve app zoom, Light and Dark appearances, native
  window tabbing, and the macOS 14 fallback path.
- Remote checks may remain unavailable during a hosting outage. Equivalent local checks
  must run, and unavailable checks must not be reported as green.

## Acceptance tests

- Every main destination, Settings category, Companion tab, Machines mode and tab,
  Docker screen, helper tab, and notch tab resolves to an accessible screen.
- Narrow, medium, wide, and minimum-size geometry preserves title baseline, leading
  content edge, action placement, readable width, and unclipped controls.
- Settings navigation and content share a grid, remain leading-anchored, preserve deep
  links and history, and work by keyboard.
- Every shared button activates at its center, label, internal whitespace, corners, and
  edges; hover and hit geometry match; keyboard, disabled, focused, selected, and
  inactive-window states are covered.
- No required action depends on hover or a context menu.
- Reduce Motion removes spatial movement and shimmer. Prefer Cross-Fade uses opacity.
- Loading tests cover cached refresh, partial, empty, error, offline, retry,
  cancellation, and success without layout shift or immediate-operation flicker.
- Task tests cover cancellation, stale-result rejection, bounded concurrency, bounded
  output, cache limits, subprocess descendants, and no post-cancel publication.
- Release measurements use at least 30 comparable raw samples and report p50 and p95 for
  launch, first frame, first useful content, cached navigation, interaction, quit,
  helper CPU and memory, CLI static commands, and representative large datasets.
- Full local CI, bundle verification, documentation, completion, parity, accessibility,
  secret, comment, and deterministic rendering checks pass before remote submission.

## Primary sources

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Windows](https://developer.apple.com/design/human-interface-guidelines/windows)
- [Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- [SwiftUI Settings](https://developer.apple.com/documentation/swiftui/settings)
- [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview)
- [Adopting SwiftUI navigation split view](https://developer.apple.com/documentation/technotes/tn3154-adopting-swiftui-navigation-split-view)
- [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)
- [Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection)
- [Pointing devices](https://developer.apple.com/design/human-interface-guidelines/pointing-devices)
- [Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- [Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [SwiftUI environment values](https://developer.apple.com/documentation/swiftui/environmentvalues)
- [Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [Loading](https://developer.apple.com/design/human-interface-guidelines/loading)
- [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)
- [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
- [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Understanding hangs](https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app)
- [Understanding hitches](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)
- [Reducing launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)
- [Visualize and optimize Swift concurrency](https://developer.apple.com/videos/play/wwdc2022/110350/)
- [Gathering information about memory use](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use)
- [Making changes to reduce memory use](https://developer.apple.com/documentation/xcode/making-changes-to-reduce-memory-use)
- [Improving app performance](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance)
- [XCTest metrics](https://developer.apple.com/documentation/xctest/xctmetric)
