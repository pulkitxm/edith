# Shared screen architecture

## Ownership

`EdithKit/UI` owns generic state, motion, surfaces, controls, and presentation.
`Edith/Shared/Views` owns page composition and app-window lifecycle integration.
Feature code supplies data, actions, and domain-specific content to these APIs.

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
