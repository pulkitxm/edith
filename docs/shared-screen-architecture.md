# Shared screen architecture

## Ownership

`EdithKit/UI` owns generic state, motion, surfaces, controls, and presentation.
`Edith/Shared/Views` owns page composition and app-window lifecycle integration.
Feature code supplies data, actions, and domain-specific content to these APIs.

## Destination and module map

| Surface | Composition and loading ownership |
| --- | --- |
| Home and suite landing pages | `PageScaffold`, shared headers, metrics, cards, and visibility-owned observation |
| Attention, Usage, Code Stats | `PageScaffold`, `ContentLoad`, the `.analytics` `PageLoading` recipe, shared activity and export components |
| Machines and fleet overview | Shared page composition and recipes, page-owned discovery, resource-owned machine sessions |
| Finder and file preview | `ContentLoad` request tickets, shared loading motion, native selection and preview content |
| Docker inspector | Separate inspect, process, and file load owners, retained refresh content, shared recovery feedback |
| Quinjet | `PageWorkspace`, per-machine project load owners, per-tab worktree load owners, retained terminal holders |
| Herdr | `PageWorkspace`, shared board loading, page-owned inventory observation, session-owned attachments |
| Companion | Retained window session, shared page composition, list and detail load owners, shared cards, grids, forms, controls, and motion |
| Studio | `PageWorkspace`, retained editors, separate source and render load owners, shared editor placeholders and recovery |
| Screen Recorder | `PageScaffold`, shared source and library load owners, visibility-owned thumbnails and previews, service-owned recordings and cancellable exports |
| Virtual Camera | `PageWorkspace`, window-owned pipeline, shared loading presentation, asynchronous thumbnail construction |
| Database | `PageWorkspace`, shared readiness and connection-list request ownership, resource-owned connected sessions |
| SEO Audit | Shared page composition, `PageLoading`, component skeletons using the shared motion clock |
| Music | Shared page composition and controls, visibility-owned metadata requests, service-owned playback |
| Calendar | Shared page composition, window visibility-owned refresh, service-owned calendar data |
| Downloads | Shared workspace and controls, page-owned estimates, service-owned transfers |
| App Maintenance and Homebrew | Shared composition, `ContentLoad` inventory and discovery ownership, shared initial recipes and retained refresh feedback |
| BlitzTree and Cleaner | Shared composition and controls, owned scans, shared discovery loading and determinate progress |
| Plugins, Extensions, Skills | Shared composition, cards, forms, provisioning controls, shared discovery load owners |
| Docs | Shared workspace, visibility-owned document work, shared theme and typography |
| Settings and About | Shared forms and page composition, visibility-owned observation, shared status, loading, and recovery components |

Native focus, scroll restoration, and deferred view construction use local view
tasks. Terminal attachment, recording, playback, installation, and editor work
use their resource owners. These lifetimes are distinct from page observation.

## Loading contract

`ContentLoad` owns request identity, cancellation, initial loading, retained
refreshes, failures, offline state, empty results, and recovery. A newer request
invalidates older results even when an underlying operation ignores cancellation.
`perform` owns asynchronous work and forwards cancellation from its caller.
The ticket API supports existing event-driven and staged loaders.

`LoadingContainer` owns lazy content construction, placeholder reveal, transition,
refresh feedback, and unavailable states. `PageLoading` supplies shared page
placeholder recipes. Feature views choose analytics, list, cards, or editor
geometry instead of implementing another loading screen.
Skeletons appear on the first frame, including between staged status and report
requests. Setup and empty results appear only after their data requests finish.

`SkeletonGroup`, `SkeletonBlock`, `SkeletonReplica`, and `LoadingIndicator` use
the same `LoadingMotion` clock and shimmer renderer. Mounting a different screen
does not start a different animation. Nested groups reuse their parent's phase.
Reduced motion renders static placeholders, and inactive scenes pause updates.
Determinate operations retain their actual progress values.

Content remains visible during refresh. A refresh failure keeps the last good
result and provides recovery feedback. Initial failure must not turn into an
empty success, setup screen, or permanent loading animation.

## Page composition

`PageScaffold` owns scrolling, gutters, content width, section spacing, bottom
padding, and the app surface. Headers may scroll with content or remain pinned.
`PageWorkspace` uses the same surface and sizing for pane-based tools that manage
their own scrolling. `PageHeader` owns responsive title, actions, and accessories.
`PageSectionHeader` owns responsive section headings.

The window host supplies `compactLayout`. Pages must not derive another compact
breakpoint from their own geometry. `PageMetrics` owns page dimensions and card
columns; `UIScale` and `Font.edithText` own zoom-aware sizing and typography.

## Page work

`pageTask` starts work only while the window is visible and automatic actions are
enabled. It restarts when its identity changes and cancels page-owned work when
the page disappears or the window becomes hidden. `pageRefresh` uses that same
ownership contract for polling, including cancellation during the delay.

App-wide services and window-retained editor or terminal sessions have longer
lifetimes. Their resource owner handles teardown; hiding a page stops discovery
and UI observation without closing a retained session or interrupting an owned
recording.

## Components and presentations

Shared controls own interaction styling, theme colors, focus, disabled state,
and sizing. Use `EdithSegmentedPicker` for segmented selection, shared surfaces
for cards, and the shared activity and export components for their respective
content. Feature-specific calculations feed those components as values.
The export button owns Command-E. The shared export sheet owns Command-C copy,
Command-S save, arrow-key navigation, animated copy confirmation, and card
transitions. Reduced motion keeps confirmation visible without spatial effects.

`edithSheet` owns Escape and outside-click dismissal. Operation ownership and
unsaved edits determine dismissibility. Global history commands are owned by the
window router and must remain available from native text, terminal, and web
responders.

## Verification

Exercise initial loading, content, empty, failure, retry, refresh failure,
superseded requests, cancellation, and re-entry. Verify the actual rendered
screens at compact and regular widths, increased zoom, both appearances, and
reduced motion. Visual evidence uses isolated synthetic services and fixtures.

Run the affected behavioral and rendering tests at each checkpoint, then the
full Makefile checks and development build at the final head. Passing source
policy checks alone does not establish visual or lifecycle correctness.
