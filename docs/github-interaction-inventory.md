# GitHub interaction inventory

This is the checked structure for product research. Completed observations and recordings stay in
the external research directory so account details and private repository content cannot enter
version control.

## Workflow record

Each focused workflow records:

| Field | Required content |
| --- | --- |
| Identifier | Stable lowercase workflow name |
| Area | Repository, file, commit, pull request, issue, Actions, Projects, or settings |
| Fixture | Repository, organization, account role, and starting state |
| Appearance | Light or dark |
| Width | Exact narrow or wide viewport |
| Authentication | Signed in, signed out, expired, insufficient scope, or no access |
| Start URL | Exact URL before the first action |
| End URL | Exact URL after the final action |
| Preconditions | Ref, file type, repository state, checks, conflicts, or permissions |
| Recording | External artifact name and capture date |
| Edith comparison | External artifact name after implementation |
| Support | Fully native, native read-only, opens on GitHub, or unavailable |
| Notes | Confirmed differences that preserve Edith's visual language |

## Interaction rows

Record each observable step in order:

| Field | Meaning |
| --- | --- |
| Step | One-based sequence number |
| Target | Visible label and accessibility label |
| Input | Click, double-click, hover, focus, key, shortcut, drag, scroll, or context menu |
| Before | Relevant visible state before input |
| After | Relevant visible state after input |
| URL transition | Old and new URL, including query and fragment |
| History | Push, replace, back, forward, reload, or no entry |
| Focus | Focus owner after the action |
| Keyboard | Shortcut and disabled-state behavior |
| Menu | Item order, roles, shortcuts, enabled state, and destructive styling |
| Feedback | Skeleton, progress, toast, inline validation, dialog, banner, or animation |
| Accessibility | Label, value, hint, announcement, and keyboard reachability |

## State matrix

Every workflow checks the states that apply:

- Initial skeleton matching final geometry
- Cached stale content with background refresh
- Empty result
- Offline with and without cached content
- Permission denied
- Missing authentication or scope
- Validation error
- Not found or deleted resource
- Primary rate limit
- Secondary rate limit
- Server error and retry
- Destructive confirmation and cancellation
- Reduced motion
- Narrow and wide layouts
- Light and dark appearances

## Skeleton comparison

For each screen, capture the skeleton and loaded state at the same viewport. Verify:

- Matching row count or a bounded representative count
- Matching column, icon, title, badge, action, and metadata geometry
- No layout shift in stable chrome
- Static placeholders under Reduce Motion
- One subtle shared shimmer otherwise
- Cached content remains visible during revalidation
- Progress indicators appear only for explicit actions

## Link inventory

Every link records:

- Source route and visible label
- Resolved typed route
- Canonical GitHub URL
- Default click behavior
- Command-click behavior
- Context menu items
- Copy Link result
- Open on GitHub result
- Back and forward behavior
- Scroll restoration behavior

## Mutation inventory

Every mutation additionally records:

- Required account role and scope
- Editable fields and validation timing
- Unsaved-change protection
- Confirmation copy and default button
- Submitted CLI or API operation shape without credentials
- Optimistic state, if any
- Success feedback
- Failure recovery and retry
- Cache entries invalidated
- URL and history behavior after success

## Completion rule

A workflow is researched only when normal navigation, keyboard and pointer paths, context menus,
loading, empty, denied, invalid, destructive, narrow, wide, light, dark, URL, and history behavior
have either been observed or marked not applicable with a reason.
