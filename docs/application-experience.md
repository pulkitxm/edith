# Application experience

The application is a collection of workspaces with one navigation, control, and
resource ownership contract. A feature should spend the window's space on its
primary task. Reading and settings forms can use a readable width; editors,
tables, terminals, and queues should use the available workspace.

## Interaction contract

- Returning to a destination retains its draft, filters, selection, and viewport.
  Each window owns its own workspace. A setting shared between windows must be
  intentional, rather than a side effect of reconstructing a page model.
- Filters describe the data currently shown. Refreshes must not clear a selected
  filter, add an exclusion, or quietly replace a user's range.
- Command-F focuses a visible search field and selects its existing query.
  Native text editors and terminals keep their own keyboard behavior. Escape in
  search clears a query first, then releases focus. Multi-step presentations go
  back before dismissing; owned operations remain protected.
- Actions have visible targets, keyboard focus, accessible names, and disabled
  feedback. Essential actions must not require hovering to discover them.
- Compact layouts keep the selected tab visible and expose every action. Higher
  zoom changes layout rather than clipping labels or squeezing controls away.
- Canvas objects use the same selection model for hit testing, movement, resize,
  naming, text editing, and undo. A completed manipulation is one undo step.
- Loading distinguishes initial work, refresh, empty results, and failure.
  Refresh retains the last good content; recovery does not require leaving the
  screen. Cancelled and superseded work cannot publish stale results.

## Resource contract

| Resource | Ownership and bound |
| --- | --- |
| Page observation | `pageTask` and `pageRefresh` stop when hidden or disabled. |
| Requests | `ContentLoad` owns cancellation and only the latest result can publish. |
| Search projections | Debounce rapid edits; filter and sort large snapshots off the main actor. |
| Long tables | Native tables recycle visible rows and keep the complete result set available. |
| Card libraries | Lazy grids or stacks construct visible content without per-row full-list work. |
| Navigation state | Window-owned models retain drafts and queries without keeping discovery running. |
| Editors and terminals | Resource owners retain documents and connections; page visibility controls drawing. |
| Recording, playback, transfer, installation | Operation owners finish or explicitly cancel work independently of navigation. |
| Previews | Visible consumers own previews and thumbnail requests. |
| Accessibility | Reduced motion pauses spatial effects; reduced transparency uses an opaque sidebar. |

Virtualization and background work solve different problems. Virtualization
bounds view construction and scrolling cost. Background projection prevents a
large filter or sort from blocking input. Stable row identities avoid replacing
selection and cells on every sample. Cached state prevents unnecessary reloads
after navigation. None of these should truncate the data silently.

## Surface review

| Surface | Primary workspace and review focus |
| --- | --- |
| Home and suite landing pages | Responsive discovery cards, readable descriptions, visible actions. |
| Agent Usage | Pinned, explicit filters; retained report during reload; lazy analytics sections. |
| Code Stats | Persistent range and facets; explicit exclusions; complete native repository table. |
| Attention | Background breakdown projection; complete native detail table; separate section positions. |
| Machines and fleet | Retained sessions, visible connection status, responsive tab navigation. |
| Machine processes | One background projection per sample or query, recycled rows, visible process actions. |
| Finder | Native selection, lazy icon and list views, retained navigation and preview ownership. |
| Docker | Independent detail loaders and recoverable errors; responsive inspector controls. |
| Herdr | Selected session stays visible; Escape navigates launch steps; terminal focus remains local. |
| Quinjet | Retained review sessions, selected tab reveal, responsive terminal and review controls. |
| Companion | Retained chat drafts and library selection; active screen owns observation. |
| Studio images | Direct selection, movement, resize, inline text and naming, bounded undo and rendering. |
| Studio video | Native corner handles, text editing, aspect-preserving image and webcam placement. |
| Studio PDF | Annotation selection after insertion and native manipulation handles. |
| LaTeX | Retained project and editor state, readable source, usable compact controls and native find. |
| Screen Recorder | Recording survives navigation; source and library requests follow visibility. |
| Virtual Camera | Stage fills available space; compact controls use the shared presentation. |
| Database | Retained connection, object and table workspace; recycled records; compact query controls. |
| SEO Audit | Background projections, retained audit state, responsive project and run controls. |
| Music | Playback owns its lifetime; lazy libraries and visibility-owned metadata requests. |
| Calendar | Service-owned events, visibility-owned refresh, responsive date navigation. |
| Downloads | Transfers survive navigation; queue uses available width; estimates have request ownership. |
| App Maintenance | Inventory query persists; navigation does not cancel owned installation work. |
| Homebrew | Recycled package table, visible inventory filters, retained discovery and mutation ownership. |
| Blitz Tree | Retained scan and selection; view choice survives navigation. |
| Plugins and Skills | Responsive preview and install actions; discovery and install have separate lifetimes. |
| Extensions | Search and category remain visible; responsive catalog and clear permission state. |
| Docs | Readable text and native document navigation; visibility-owned work. |
| Settings and About | Native forms, semantic text and focus, bounded reading width. |

## Verification

Use isolated defaults, synthetic records, and mocked services. Test regular and
compact widths, 1.6 zoom, light and dark appearances, and reduced motion. A render
test alone establishes that a screen draws, not that its controls are reachable.
Exercise native events, viewport restoration, focus, final-row access, and
selection across refresh and re-entry.

`ApplicationListExperienceTests` loads 10,000 process and package rows, reaches
the final row, and verifies that native row views remain bounded. Projection
tests cover stable ordering, full-result search, cancellation and supersession.
`PageScrollPositionTests` exercises destination and section re-entry using the
native scroll view, including shorter content. Shared control tests cover
disabled pointer actions, keyboard search, focus, compact headers, zoom and
presentation ownership. `UISmokeTests` renders every main destination at regular
and compact widths in both appearances.

Timing comparisons require the same machine, build, synthetic workload, and
power conditions. Keep raw measurements local until sanitized. Final visual
evidence must show the actual product using synthetic fixtures, with no personal
data, project paths, credentials, or original captures uploaded.
